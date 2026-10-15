import sys,re,struct,os,zlib
src,out=sys.argv[1],sys.argv[2]
d=open(src,'rb').read()
cov=[]
for h in [m.start() for m in re.finditer(rb'BIN\.HDR\.',d)]:
    r=h+16
    if b'NNNN' != d[r+0x20c:r+0x210]: continue
    start=h
    while d[r+0x20c:r+0x210]==b'NNNN':
        path=d[r:r+260].split(b'\0')[0].decode('latin1').replace('\\','/')
        size=struct.unpack_from('<Q',d,r+0x220)[0]
        crc=struct.unpack_from('<I',d,r+0x228)[0]
        data=d[r+0x230:r+0x230+size]
        ok='crc-ok' if (zlib.crc32(data)&0xffffffff)==crc else 'crc?'
        p=os.path.normpath(os.path.join(out,path.lstrip('/')))
        assert p.startswith(os.path.abspath(out))
        os.makedirs(os.path.dirname(p),exist_ok=True); open(p,'wb').write(data)
        print('%08x %9d %s %s'%(r+0x230,size,ok,path))
        r=r+0x230+size
    cov.append((start,r))
print('covered',[(hex(a),hex(b)) for a,b in cov])
