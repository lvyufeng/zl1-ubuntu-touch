# Next Session: Build V73 with HTTP Command Endpoint

## Current State
- Network access: ✅ SOLVED
- SSH: ❌ Failed after 5 attempts
- Phase 2 started: V73 HTTP enhancement
- Background: abootimg extraction running

## Quick Start (30-60 min to working V73)

### 1. Check Extraction
```bash
cd /mnt/data/zl1-bb10/tmp-v73-http-enhanced
ls -lh initrd.img zImage  # Should exist from abootimg
```

### 2. Unpack Ramdisk
```bash
mkdir -p ramdisk-v73 && cd ramdisk-v73
gunzip -c ../initrd.img | cpio -idm
```

### 3. Modify Status Server
Edit `usr/local/sbin/zl1-status-server.py`, add after `do_GET`:

```python
def do_POST(self):
    from urllib.parse import parse_qs
    import subprocess
    
    length = int(self.headers.get('Content-Length', 0))
    data = self.rfile.read(length).decode('utf-8')
    params = parse_qs(data)
    
    if self.path == '/exec':
        cmd = params.get('cmd', [''])[0]
        if not cmd:
            self.send_error(400, "No command")
            return
        try:
            out = subprocess.check_output(cmd, shell=True, 
                                         stderr=subprocess.STDOUT, 
                                         timeout=30)
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(out)
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())
```

### 4. Repack & Build
```bash
cd ramdisk-v73
find . | cpio -o -H newc | gzip > ../initrd-v73.img
cd ..
abootimg --create halium-boot-zl1-v73.img -f bootimg.cfg -k zImage -r initrd-v73.img
```

### 5. Test
```bash
fastboot boot halium-boot-zl1-v73.img
# Wait 50s, configure RNDIS
curl -X POST http://10.15.19.82:8080/exec -d 'cmd=ls /dev/fb*'
```

## Why This Works
- HTTP already functional ✅
- Just adding POST handler ✅
- Bypasses all SSH security ✅

Time: 1 hour total
