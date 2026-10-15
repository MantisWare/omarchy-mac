#!/usr/bin/python3
"""User-selectable, transactional GPU placement for local model runtimes."""
import base64, fcntl, json, os, re, shutil, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path
from detect import gpus, llama_device_output, process_allocations, user_processes

STATE_DIR=Path(os.environ.get("OMARCHY_EGPU_STATE_DIR",Path.home()/".local/state/omarchy")); STATE_FILE=STATE_DIR/"egpu-model-placement.json"; OPERATION_FILE=STATE_DIR/"egpu-model-operation.json"; LOCK_FILE=STATE_DIR/"egpu-model-placement.lock"; STATE_LOCK_FILE=STATE_DIR/"egpu-model-state.lock"
JOURNAL_FILE=STATE_DIR/"egpu-model-transaction.json"
ECHO_ENV=Path(os.environ.get("OMARCHY_EGPU_ECHO_ENV",Path.home()/".config/echo-craft/.env")); ECHO_SERVICE=os.environ.get("OMARCHY_EGPU_ECHO_SERVICE","echocraft.service")
LLAMA_BIN=os.environ.get("OMARCHY_EGPU_LLAMA_BIN","/usr/bin/llama-server"); LLAMA_SERVICE=os.environ.get("OMARCHY_EGPU_LLAMA_SERVICE","mia-local-llm.service"); LLAMA_PRESET=Path(os.environ.get("OMARCHY_EGPU_LLAMA_PRESET",Path.home()/".config/omarchy/egpu/llama-models.ini")); LLAMA_URL=os.environ.get("OMARCHY_EGPU_LLAMA_MODELS_URL","http://127.0.0.1:8127/models"); PROC=Path(os.environ.get("OMARCHY_EGPU_PROC","/proc"))

def read_json(path,default):
 try:
  value=json.loads(path.read_text()); return value if isinstance(value,type(default)) else default
 except (OSError,ValueError,TypeError): return default
def atomic_write(path,data,mode=0o600):
 path.parent.mkdir(parents=True,exist_ok=True); fd,tmp=tempfile.mkstemp(prefix=path.name+".",dir=path.parent)
 try:
  with os.fdopen(fd,"wb") as out: out.write(data)
  os.chmod(tmp,mode); os.replace(tmp,path)
 finally:
  try: os.unlink(tmp)
  except FileNotFoundError: pass
def write_json(path,value): atomic_write(path,(json.dumps(value,indent=2,sort_keys=True)+"\n").encode())
def update_state(mutator):
 STATE_DIR.mkdir(parents=True,exist_ok=True)
 with STATE_LOCK_FILE.open("a+") as lock:
  fcntl.flock(lock,fcntl.LOCK_EX); state=read_json(STATE_FILE,{"models":{}}); mutator(state); write_json(STATE_FILE,state); return state
def merge_model_observations(observations):
 def merge(state):
  for model_id,observed in observations.items():
   saved=state.setdefault("models",{}).setdefault(model_id,{})
   for key,value in observed.items(): saved[key]=value
 return update_state(merge)
def model_arg(args):
 for i,arg in enumerate(args[:-1]):
  if arg in ("-m","--model"): return args[i+1]
 return ""
def env_values(path):
 try: return dict(line.split("=",1) for line in path.read_text().splitlines() if "=" in line and not line.lstrip().startswith("#"))
 except OSError: return {}
def identity(device): return {k:device.get(k) for k in ("vendor","device","external")}
def resolve(saved,key,devices):
 value=saved.get(key,"")
 if any(d["id"]==value for d in devices): return value
 ident=saved.get(key+"Identity",{}); matches=[d for d in devices if ident and all(d.get(k)==v for k,v in ident.items())]
 return matches[0]["id"] if len(matches)==1 else value
def dri_prime(device_id): return "pci-"+device_id.replace(":","_").replace(".","_")+"!"
def binary_has_vulkan(path):
 try:
  with Path(path).open("rb") as stream:
   while chunk:=stream.read(1024*1024):
    if b"ggml_vulkan" in chunk.lower(): return True
 except OSError: pass
 return False
def configured_echo_binary(processes):
 for pid,comm,args in processes:
  if comm.startswith("whisper-server"):
   try: return str((PROC/str(pid)/"exe").resolve(strict=True))
   except OSError: return args[0] if args else ""
 candidate=Path.home()/".config/echo-craft/bin/whisper-vulkan/whisper-server-linux-x64-vulkan"
 return str(candidate) if candidate.is_file() else ""

def echo_model(processes):
 for pid,comm,args in processes:
  if comm.startswith("whisper-server"):
   path=model_arg(args); allocations=process_allocations(pid,PROC); size=Path(path).stat().st_size*2 if path and Path(path).is_file() else 0
   return {"id":"echocraft-whisper","name":Path(path).stem if path else "EchoCraft Whisper","kind":"Speech","runtime":"EchoCraft / whisper.cpp","path":path,"executable":configured_echo_binary(processes),"loaded":True,"devices":sorted(allocations),"required":max([size,*allocations.values()]) or None}
 if ECHO_ENV.is_file():
  configured=env_values(ECHO_ENV).get("LOCAL_WHISPER_MODEL",""); path=Path.home()/".cache/openwhispr/whisper-models"/f"ggml-{configured}.bin"
  return {"id":"echocraft-whisper","name":f"ggml-{configured}" if configured else "EchoCraft Whisper","kind":"Speech","runtime":"EchoCraft / whisper.cpp","path":str(path) if configured else "","executable":configured_echo_binary(processes),"loaded":False,"devices":[],"required":path.stat().st_size*2 if path.is_file() else None}

def router_models():
 try:
  fixture=os.environ.get("OMARCHY_EGPU_LLAMA_MODELS_FIXTURE")
  if fixture: data=json.loads(Path(fixture).read_text())
  else:
   with urllib.request.urlopen(urllib.request.Request(LLAMA_URL,headers={"Accept":"application/json"}),timeout=2) as response: data=json.load(response)
  return data.get("data",data.get("models",[])) if isinstance(data,dict) else data if isinstance(data,list) else []
 except (OSError,ValueError): return []
def router_status(entry):
 status=entry.get("status","")
 return str(status.get("value","") if isinstance(status,dict) else status).lower()
def router_path(entry):
 status=entry.get("status",{}); args=status.get("args",entry.get("args",[])) if isinstance(status,dict) else entry.get("args",[])
 if isinstance(args,dict): nested=args.get("model") or args.get("path") or ""
 elif isinstance(args,list): nested=model_arg([str(value) for value in args])
 else: nested=""
 return str(nested or entry.get("path") or entry.get("model") or "")
def router_args(entry):
 status=entry.get("status",{}); args=status.get("args",entry.get("args",[])) if isinstance(status,dict) else entry.get("args",[])
 return [str(value) for value in args] if isinstance(args,list) else []
def arg_value(args,name):
 try: return args[args.index(name)+1]
 except (ValueError,IndexError): return ""
def valid_router_id(value): return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:+/@-]{0,127}",value))
def router_action(router_id,action,timeout=25):
 url=LLAMA_URL.rstrip("/")+"/"+action; payload=json.dumps({"model":router_id}).encode()
 deadline=time.monotonic()+timeout; last="router did not respond"
 while time.monotonic()<deadline:
  try:
   request=urllib.request.Request(url,data=payload,method="POST",headers={"Accept":"application/json","Content-Type":"application/json"})
   with urllib.request.urlopen(request,timeout=3) as response:
    if 200<=response.status<300: return
  except Exception as error: last=str(error)
  time.sleep(1)
 raise RuntimeError(f"Could not {action} llama model {router_id}: {last}")
def load_router_models(model_ids):
 for router_id in dict.fromkeys(model_ids): router_action(router_id,"load")
def backend_devices(extra=None):
 found=[]
 for line in llama_device_output(extra).splitlines():
  match=re.match(r"\s*([^:\s]+)\s*:\s*(.+?)\s*$",line)
  if match and match.group(2)!="(none)" and match.group(1).lower()!="available": found.append((match.group(1),match.group(2)))
 return found
def backend_identity(name): return re.sub(r"\s+\([0-9]+ MiB,\s*[0-9]+ MiB free\)\s*$","",name)
def backend_for(gpu):
 filtered=backend_devices({"DRI_PRIME":dri_prime(gpu["id"])})
 if len(filtered)!=1: raise RuntimeError(f"llama.cpp could not uniquely identify {gpu['name']} through Mesa.")
 selected=backend_identity(filtered[0][1]); matches=[key for key,name in backend_devices() if backend_identity(name)==selected]
 if len(matches)!=1: raise RuntimeError(f"llama.cpp device identity for {gpu['name']} is ambiguous.")
 return matches[0]
def package_installed(name):
 try: return subprocess.run(["pacman","-Q",name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False).returncode==0
 except OSError: return False
def llama_models(processes,devices,entries=None):
 workers={}
 for pid,comm,args in processes:
  path=model_arg(args)
  if comm.startswith("llama-server") and path: workers.setdefault(path,[]).append(pid)
 reason="" if package_installed("ggml-vulkan") else "Install ggml-vulkan to enable the llama.cpp Vulkan backend."
 if not reason and not backend_devices(): reason="ggml-vulkan is installed, but llama.cpp reports no Vulkan devices."
 result=[]
 for entry in router_models() if entries is None else entries:
  rid=str(entry.get("id") or entry.get("name") or ""); path=router_path(entry)
  if not rid: continue
  status_value=router_status(entry); loaded=status_value in ("loaded","loading") or bool(workers.get(path)); allocations={}
  for pid in workers.get(path,[]):
   for gpu,amount in process_allocations(pid,PROC).items(): allocations[gpu]=max(allocations.get(gpu,0),amount)
  dominant=max(allocations,key=allocations.get) if allocations else ""
  allowed=[d["id"] for d in devices if d["selectable"]]
  why=reason or ("Load this model before changing placement; success requires observed DRM allocation." if not loaded else "Apply restarts the model router; live VRAM migration is not supported.")
  capable=not reason and loaded and bool(allowed)
  if not valid_router_id(rid): capable=False; why="This router model ID contains characters that are unsafe in a llama.cpp preset section."
  meta=entry.get("meta") or {}; model_size=meta.get("size") or (Path(path).stat().st_size if path and Path(path).is_file() else None)
  mmproj=arg_value(router_args(entry),"--mmproj"); mmproj_size=Path(mmproj).stat().st_size if mmproj and Path(mmproj).is_file() else 0
  base=model_size+mmproj_size if model_size else None; required=base+max(512*1024*1024,base//4) if base else None
  estimate="Estimated model + projector + conservative runtime/KV margin." if required else "GPU memory requirement unknown; llama fit and observed allocation decide."
  result.append({"id":"llama:"+rid,"routerId":rid,"name":rid,"kind":"LLM","runtime":"llama.cpp","path":path,"mmproj":mmproj,"routerStatus":status_value,"loaded":loaded,"devices":[dominant] if dominant else [],"current":dominant,"required":required,"estimated":bool(required),"capable":capable,"reason":why,"estimateReason":estimate,"allowedDevices":allowed,"policy":"User assignable; unavailable preferred GPUs fall back safely."})
 return result

def operation():
 current=read_json(OPERATION_FILE,{})
 if current.get("status") in ("offloading","unloading","loading") and time.time()-current.get("updated",0)>120:
  current.update(status="error",message="The previous GPU reload was interrupted; recovery will run on the next reconcile.",updated=time.time())
  write_json(OPERATION_FILE,current)
 return {} if current.get("status")=="success" and time.time()-current.get("updated",0)>12 else current
def notify(headline,body,nid="",persistent=False,critical=False):
 command=shutil.which("omarchy-notification-send")
 if not command: return nid
 args=[command,"--app-name","miaOS GPUs","-p"]+(["-r",str(nid)] if nid else [])+(["-t","0"] if persistent else [])+(["-u","critical"] if critical else [])
 try:
  result=subprocess.run(args+[headline,body],capture_output=True,text=True,timeout=5,check=False); return result.stdout.strip() or nid
 except (OSError,subprocess.TimeoutExpired): return nid
def update_operation(status,message,model="",target="",visible=False,critical=False):
 previous=read_json(OPERATION_FILE,{}); nid=previous.get("notificationId","") if previous.get("model")==model else ""
 if visible: nid=notify("Moving local model",message,nid,status not in ("success","error"),critical)
 value={"status":status,"message":message,"model":model,"target":target,"updated":time.time()}
 if nid: value["notificationId"]=nid
 write_json(OPERATION_FILE,value)
def progress(status,message,model,target): update_operation(status,message,model,target,True)
def replace_env(path,updates):
 original=path.read_bytes(); output=[]; written=set()
 for line in original.decode().splitlines():
  key=line.split("=",1)[0] if "=" in line and not line.lstrip().startswith("#") else ""
  if key in updates and key not in written: output.append(f"{key}={updates[key]}"); written.add(key)
  elif key not in updates: output.append(line)
 output += [f"{k}={v}" for k,v in updates.items() if k not in written]; atomic_write(path,("\n".join(output)+"\n").encode(),path.stat().st_mode&0o777); return original
def restart(service): subprocess.run(["systemctl","--user","restart",service],timeout=30,check=True)
def save_journal(path,existed,original,service,prior_loaded,previous,model_id,router_id="",selected_was_loaded=False):
 write_json(JOURNAL_FILE,{"path":str(path),"existed":existed,"original":base64.b64encode(original).decode(),"service":service,"priorLoaded":prior_loaded,"previous":previous,"model":model_id,"selectedRouterId":router_id,"selectedWasLoaded":bool(selected_was_loaded),"created":time.time(),"attempts":0})
def journal_load_ids(journal):
 ids=list(journal.get("priorLoaded",[])); saved=read_json(STATE_FILE,{"models":{}}).get("models",{}).get(journal.get("model",""),{})
 selected=str(journal.get("selectedRouterId") or saved.get("runtimeMetadata",{}).get("routerId", ""))
 intended=journal.get("selectedWasLoaded") if "selectedWasLoaded" in journal else saved.get("wasLoaded",False)
 if intended and valid_router_id(selected): ids.append(selected)
 return list(dict.fromkeys(ids))
def recovery_target(snapshot,model_id,previous=""):
 devices=[device for device in snapshot["gpus"] if device.get("selectable")]; present={device["id"] for device in devices}; model=next((item for item in snapshot["models"] if item["id"]==model_id),None)
 if not model: return ""
 saved=read_json(STATE_FILE,{"models":{}}).get("models",{}).get(model_id,{})
 candidates=[previous,resolve(saved,"fallback",devices),resolve(saved,"lastGood",devices),resolve(saved,"preferred",devices)]
 candidates += model.get("allowedDevices",[])
 return next((candidate for candidate in candidates if candidate in present and candidate in model.get("allowedDevices",[])),"")
def configure_recovery(journal,target,snapshot):
 model_id=journal.get("model",""); path=Path(journal["path"]); service=journal.get("service",LLAMA_SERVICE)
 if service==ECHO_SERVICE: replace_env(path,{"WHISPER_VULKAN_ENABLED":"true","WHISPER_VULKAN_DEVICE":"0","DRI_PRIME":dri_prime(target)})
 else: atomic_write(path,preset_text(snapshot["models"],snapshot["gpus"],read_json(STATE_FILE,{"models":{}}),(model_id,target)))
 restart(service)
 if service==LLAMA_SERVICE: load_router_models(journal_load_ids(journal))
 if not wait_for_model(model_id,target): raise RuntimeError("Recovery restarted on an available fallback, but DRM placement could not be verified.")
 def remember(state):
  saved=state.setdefault("models",{}).setdefault(model_id,{}); device=next(item for item in snapshot["gpus"] if item["id"]==target)
  saved.update(lastGood=target,fallback=target,fallbackIdentity=identity(device),wasLoaded=True,updated=time.time())
 update_state(remember)
def recover_journal():
 journal=read_json(JOURNAL_FILE,{})
 if not journal: return True
 delay=min(30,2**min(int(journal.get("attempts",0)),5))
 if journal.get("lastAttempt") and time.time()-journal["lastAttempt"]<delay: return False
 journal["lastAttempt"]=time.time(); journal["attempts"]=int(journal.get("attempts",0))+1; write_json(JOURNAL_FILE,journal)
 path=Path(journal.get("path",""))
 if path not in (ECHO_ENV,LLAMA_PRESET): raise RuntimeError("Refusing an invalid GPU recovery journal path.")
 original=base64.b64decode(journal.get("original","").encode())
 if journal.get("existed"): atomic_write(path,original)
 elif path.exists(): path.unlink()
 restored=True
 try:
  restart(journal.get("service",LLAMA_SERVICE))
  if journal.get("service")==LLAMA_SERVICE: load_router_models(journal_load_ids(journal))
 except Exception:
  restored=False
 previous=journal.get("previous","")
 previous_available=previous and any(device.get("id")==previous and device.get("selectable") for device in gpus())
 if restored and previous_available and wait_for_model(journal.get("model",""),previous):
  JOURNAL_FILE.unlink(missing_ok=True); update_operation("error","Recovered configuration from an interrupted GPU reload; prior GPU placement verified.",visible=True); return True
 snapshot=inventory(); target=recovery_target(snapshot,journal.get("model",""),previous)
 if not target: raise RuntimeError("Recovered configuration, but no available fallback GPU could be selected; recovery will retry.")
 configure_recovery(journal,target,snapshot)
 JOURNAL_FILE.unlink(missing_ok=True)
 update_operation("error","Recovered an interrupted GPU reload on an available fallback; the preferred GPU remains selected for reconnection.",visible=True)
 return True
def wait_for_model(model_id,target,timeout=40):
 deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  current={m["id"]:m for m in inventory()["models"]}.get(model_id)
  if current and current.get("loaded") and target in current.get("devices",[]): return True
  time.sleep(1)
 return False
def preset_text(models,devices,state,override=None):
 lines=["version = 1",""]; selectable=[d for d in devices if d["selectable"]]; external=next((d for d in selectable if d["external"]),None); default=(external or next(iter(selectable),None) or {}).get("id","")
 for model in models:
  if model.get("runtime")!="llama.cpp": continue
  rid=model["routerId"]
  if not valid_router_id(rid): continue
  saved=state.get("models",{}).get(model["id"],{}); target=override[1] if override and override[0]==model["id"] else ""
  target=target or resolve(saved,"preferred",devices) or model.get("current","") or default
  if not any(d["id"]==target for d in selectable): target=resolve(saved,"fallback",devices) or default
  gpu=next((d for d in devices if d["id"]==target),None)
  if gpu: lines += [f"[{rid}]",f"device = {backend_for(gpu)}","n-gpu-layers = all","fit = on",""]
 return "\n".join(lines).encode()

def inventory():
 devices=gpus(); selectable=[d for d in devices if d["selectable"]]; processes=list(user_processes(PROC)); state=read_json(STATE_FILE,{"models":{}}); models=[]; speech=echo_model(processes); observations={}
 if speech:
  executable=speech.get("executable",""); vulkan=binary_has_vulkan(executable)
  speech["allowedDevices"]=[device["id"] for device in selectable]; speech["capable"]=bool(selectable and ECHO_ENV.is_file() and vulkan)
  if not selectable: speech["reason"]="No supported GPU is currently available."
  elif not executable: speech["reason"]="EchoCraft's pinned Vulkan whisper backend is not installed yet."
  elif not vulkan: speech["reason"]=f"EchoCraft's configured whisper executable is not Vulkan-capable: {executable}"
  else: speech["reason"]="Apply reloads EchoCraft on the selected GPU."
  models.append(speech)
 router_entries=router_models(); models += llama_models(processes,devices,router_entries)
 seen={model["id"] for model in models}
 for model in list(models):
  if model.get("runtime")!="llama.cpp": continue
  metadata={"runtime":"llama.cpp","routerId":model["routerId"],"name":model["name"],"path":model.get("path",""),"mmproj":model.get("mmproj",""),"required":model.get("required")}; observed={"runtimeMetadata":metadata}
  status_value=model.get("routerStatus","")
  observed_loaded=True if status_value in ("loaded","loading") else False if status_value=="unloaded" else None
  if observed_loaded is not None: observed["wasLoaded"]=observed_loaded
  observations[model["id"]]=observed
 if observations: state=merge_model_observations(observations)
 for model_id,saved in state.get("models",{}).items():
  metadata=saved.get("runtimeMetadata",{})
  if model_id in seen or metadata.get("runtime")!="llama.cpp": continue
  allowed=[d["id"] for d in selectable]
  models.append({"id":model_id,"routerId":metadata.get("routerId",model_id.removeprefix("llama:")),"name":metadata.get("name",model_id),"kind":"LLM","runtime":"llama.cpp","path":metadata.get("path",""),"mmproj":metadata.get("mmproj",""),"loaded":False,"devices":[],"required":metadata.get("required"),"estimated":bool(metadata.get("required")),"capable":False,"reason":"The llama router is unavailable; miaOS will retry the stored placement during reconciliation.","allowedDevices":allowed,"policy":"User assignable; unavailable preferred GPUs fall back safely."})
 if any("comfy" in " ".join(args).lower() for _,_,args in processes): models.append({"id":"comfyui-runtime","name":"ComfyUI runtime","kind":"Image","runtime":"ComfyUI","loaded":True,"devices":[],"required":None,"capable":False,"allowedDevices":[],"reason":"This ComfyUI service is CPU-only; no verifiable GPU reload adapter is installed."})
 for model in models:
  saved=state.get("models",{}).get(model["id"],{}); model["current"]=model.get("current") or (model["devices"][0] if model["devices"] else "")
  external=next((d for d in selectable if d["external"]),None); default=(external or next(iter(selectable),None) or {}).get("id","")
  model["preferred"]=resolve(saved,"preferred",devices) or model["current"] or default
  model["fits"]={}
  for device in devices:
   required,available=model.get("required"),device.get("available")
   if device["id"] not in model.get("allowedDevices",[]): fit=("unsupported","Blocked by model policy")
   elif required is None or available is None: fit=("unknown","GPU memory fit unknown")
   elif available>=required or model["current"]==device["id"]: fit=("fits","Estimated to fit GPU memory" if model.get("estimated") else "Fits available GPU memory")
   else: fit=("insufficient","Not enough free GPU memory")
   model["fits"][device["id"]]={"status":fit[0],"label":fit[1]}
 return {"gpus":devices,"models":models,"operation":operation()}

def transition(model_id,target,remember=True,recover=False):
 before=inventory(); models={m["id"]:m for m in before["models"]}; devices={d["id"]:d for d in before["gpus"]}; model=models.get(model_id); device=devices.get(target)
 if not model: raise RuntimeError("Model runtime is no longer loaded.")
 if not model.get("capable") and not (recover and model.get("runtime")=="llama.cpp"): raise RuntimeError(model.get("reason","This runtime cannot change GPU placement."))
 if not device or target not in model.get("allowedDevices",[]): raise RuntimeError("The selected GPU is unavailable or blocked by model policy.")
 if model.get("fits",{}).get(target,{}).get("status")=="insufficient": raise RuntimeError("The model does not fit the selected GPU's available memory.")
 state=read_json(STATE_FILE,{"models":{}}); saved=state.setdefault("models",{}).setdefault(model_id,{}); previous=model.get("current",""); available=list(devices.values()); fallback=resolve(saved,"fallback",available) or previous or next((item["id"] for item in available if item["id"]!=target and item["id"] in model.get("allowedDevices",[])),""); original=b""; existed=False
 path=ECHO_ENV if model_id=="echocraft-whisper" else LLAMA_PRESET; service=ECHO_SERVICE if model_id=="echocraft-whisper" else LLAMA_SERVICE
 prior_loaded=list(dict.fromkeys(item["routerId"] for item in before["models"] if item.get("runtime")=="llama.cpp" and item.get("loaded")))
 try:
  progress("offloading",f"Preparing to offload {model['name']}…",model_id,target)
  if model_id=="echocraft-whisper": existed=path.exists(); original=path.read_bytes() if existed else b""
  elif model.get("runtime")=="llama.cpp": existed=path.exists(); original=path.read_bytes() if existed else b""
  else: raise RuntimeError("No verified reload adapter is installed for this runtime.")
  selected_router=(model.get("routerId","") or saved.get("runtimeMetadata",{}).get("routerId","")) if model.get("runtime")=="llama.cpp" else ""
  selected_was_loaded=bool(model.get("loaded") or saved.get("wasLoaded"))
  save_journal(path,existed,original,service,prior_loaded,previous,model_id,selected_router,selected_was_loaded)
  if model_id=="echocraft-whisper": replace_env(path,{"WHISPER_VULKAN_ENABLED":"true","WHISPER_VULKAN_DEVICE":"0","DRI_PRIME":dri_prime(target)})
  else: atomic_write(path,preset_text(before["models"],before["gpus"],state,(model_id,target)))
  progress("unloading",f"Unloading {model['name']} from its current device…",model_id,target); restart(service); progress("loading",f"Loading {model['name']} on {device['name']}…",model_id,target)
  if model.get("runtime")=="llama.cpp": load_router_models([model["routerId"],*prior_loaded])
  if not wait_for_model(model_id,target): raise RuntimeError("Runtime restarted, but DRM allocation on the selected device was not verified.")
  remember_preference=remember
  def store_placement(current_state):
   current=current_state.setdefault("models",{}).setdefault(model_id,{})
   if remember_preference:
    current["preferred"]=target; current["preferredIdentity"]=identity(device)
    if fallback and fallback!=target: current["fallback"]=fallback; current["fallbackIdentity"]=identity(devices.get(fallback,{}))
   current["lastGood"]=target; current["lastGoodIdentity"]=identity(device); current["wasLoaded"]=True; current["updated"]=time.time()
  update_state(store_placement); JOURNAL_FILE.unlink(missing_ok=True); progress("success",f"{model['name']} is loaded on {device['name']}.",model_id,target)
 except Exception as error:
  rollback=""
  try:
   if not recover_journal(): rollback=" Rollback recovery is waiting for its bounded retry delay."
   else: rollback=" Rollback recovered the model on a verified available GPU."
  except Exception as failure: rollback=f" Rollback remains pending and will retry: {failure}"
  message=str(error)+rollback; update_operation("error",message,model_id,target,True,True); raise RuntimeError(message) from error
def reconcile():
 with LOCK_FILE.open("a+") as lock:
  try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  except BlockingIOError: return
  if not recover_journal(): return
  current=inventory(); present={d["id"] for d in current["gpus"] if d["selectable"]}; state=read_json(STATE_FILE,{"models":{}}); last=current.get("operation",{})
  for model in current["models"]:
   saved=state.get("models",{}).get(model["id"],{}); target=model.get("preferred","")
   if not model.get("capable"):
    recoverable=model.get("runtime")=="llama.cpp" and saved.get("runtimeMetadata") and saved.get("wasLoaded") and package_installed("ggml-vulkan") and backend_devices()
    if not recoverable: continue
   if target not in present: target=resolve(saved,"fallback",current["gpus"])
   if target in present and model.get("current")!=target:
    if last.get("status")=="error" and last.get("model")==model["id"] and last.get("target")==target and time.time()-last.get("updated",0)<300: continue
    transition(model["id"],target,False,True); return
def main(argv):
 STATE_DIR.mkdir(parents=True,exist_ok=True)
 if len(argv)==1 or argv[1]=="inventory": print(json.dumps(inventory())); return 0
 if argv[1]=="apply" and len(argv)==4:
  with LOCK_FILE.open("a+") as lock: fcntl.flock(lock,fcntl.LOCK_EX); transition(argv[2],argv[3])
  return 0
 if argv[1]=="reconcile" and len(argv)==2: reconcile(); return 0
 print("Usage: manager.py [inventory|apply MODEL GPU|reconcile]",file=sys.stderr); return 2
if __name__=="__main__":
 try: sys.exit(main(sys.argv))
 except Exception as error:
  current=read_json(OPERATION_FILE,{})
  if current.get("status")!="error" or time.time()-current.get("updated",0)>2: update_operation("error",str(error),sys.argv[2] if len(sys.argv)>2 else "",sys.argv[3] if len(sys.argv)>3 else "",True,True)
  print(str(error),file=sys.stderr); sys.exit(1)
