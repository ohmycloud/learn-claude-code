import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from utils import add

def test_add():
    assert add(1, 2) == 3
