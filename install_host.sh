#!/usr/bin/env python3
"""
Native Messaging Host for AntiGravity IDE Bridge
=================================================
This script handles communication between Chrome extension and the Bridge Server.
Chrome sends JSON messages via stdin, and we respond via stdout.
"""

import json
import struct
import subprocess
import sys
import os
import signal
import time
import urllib.request
import urllib.error

# Global reference to server process
server_process = None


def get_script_dir():
    """Get the directory where this script is located."""
    return os.path.dirname(os.path.abspath(__file__))


def send_message(message):
    """Send a message to Chrome extension via stdout."""
    encoded = json.dumps(message).encode('utf-8')
    # Chrome native messaging protocol: 4-byte length prefix (little-endian)
    sys.stdout.buffer.write(struct.pack('<I', len(encoded)))
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.flush()


def read_message():
    """Read a message from Chrome extension via stdin."""
    # Read 4-byte length prefix
    raw_length = sys.stdin.buffer.read(4)
    if not raw_length:
        return None
    
    # Unpack length (little-endian unsigned int)
    message_length = struct.unpack('<I', raw_length)[0]
    
    # Read the message
    message = sys.stdin.buffer.read(message_length).decode('utf-8')
    return json.loads(message)


def check_server_health():
    """Check if the Bridge Server is running by hitting the health endpoint."""
    try:
        req = urllib.request.Request(
            'http://127.0.0.1:8000/health',
            method='GET'
        )
        with urllib.request.urlopen(req, timeout=2) as response:
            if response.status == 200:
                data = json.loads(response.read().decode('utf-8'))
                return {
                    'running': True,
                    'browser_connected': data.get('browser_connected', False)
                }
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError):
        pass
    
    return {'running': False, 'browser_connected': False}


def start_server():
    """Start the Bridge Server as a subprocess."""
    global server_process
    
    # Check if already running
    status = check_server_health()
    if status['running']:
        return {'success': True, 'message': 'Server already running'}
    
    try:
        script_dir = get_script_dir()
        server_script = os.path.join(script_dir, 'bridge_server.py')
        
        if not os.path.exists(server_script):
            return {'success': False, 'message': f'Server script not found: {server_script}'}
        
        # Start server in background
        # Use pythonw on Windows to avoid console, python3 on Mac/Linux
        python_cmd = sys.executable
        
        server_process = subprocess.Popen(
            [python_cmd, server_script],
            cwd=script_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True  # Detach from parent process
        )
        
        # Wait a moment for server to start
        time.sleep(1.5)
        
        # Verify it started
        status = check_server_health()
        if status['running']:
            return {'success': True, 'message': 'Server started successfully', 'pid': server_process.pid}
        else:
            return {'success': False, 'message': 'Server failed to start'}
    
    except Exception as e:
        return {'success': False, 'message': f'Error starting server: {str(e)}'}


def stop_server():
    """Stop the Bridge Server."""
    global server_process
    
    # First try to kill our tracked process
    if server_process:
        try:
            server_process.terminate()
            server_process.wait(timeout=3)
            server_process = None
        except:
            pass
    
    # Also try to find and kill any server on port 8000
    try:
        # Use lsof to find process on port 8000 (Mac/Linux)
        result = subprocess.run(
            ['lsof', '-ti', ':8000'],
            capture_output=True,
            text=True
        )
        if result.stdout.strip():
            pids = result.stdout.strip().split('\n')
            for pid in pids:
                try:
                    os.kill(int(pid), signal.SIGTERM)
                except:
                    pass
    except:
        pass
    
    # Verify it stopped
    time.sleep(0.5)
    status = check_server_health()
    
    if not status['running']:
        return {'success': True, 'message': 'Server stopped'}
    else:
        return {'success': False, 'message': 'Server may still be running'}


def handle_message(message):
    """Process incoming message and return response."""
    command = message.get('command', '')
    
    if command == 'start_server':
        return start_server()
    
    elif command == 'stop_server':
        return stop_server()
    
    elif command == 'check_status':
        status = check_server_health()
        return {
            'success': True,
            'server_running': status['running'],
            'browser_connected': status['browser_connected']
        }
    
    else:
        return {'success': False, 'message': f'Unknown command: {command}'}


def main():
    """Main loop to handle messages from Chrome."""
    while True:
        message = read_message()
        if message is None:
            break
        
        response = handle_message(message)
        send_message(response)


if __name__ == '__main__':
    main()
