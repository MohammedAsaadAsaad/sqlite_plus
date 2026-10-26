"""Verify pinned native window callback order and cross-open every Dart image."""
from generate_window_evaluation_oracle import cases
from verify_insert_stream import main

if __name__ == '__main__':
    main(cases, 'window_evaluation_oracle.json')
