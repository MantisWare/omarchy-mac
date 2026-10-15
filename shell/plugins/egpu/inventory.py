#!/usr/bin/python3

import json

from manager import inventory


if __name__ == "__main__":
    print(json.dumps(inventory()))
