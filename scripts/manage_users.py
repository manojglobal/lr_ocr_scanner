#!/usr/bin/env python3
"""
Convenience CLI Runner for Developer User Management
"""
import os
import sys

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND_DIR = os.path.join(BASE_DIR, "backend")

if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from manage_users import main

if __name__ == "__main__":
    main()
