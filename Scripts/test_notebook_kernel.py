#!/usr/bin/env python3
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parent.parent


class KernelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='kernel-check-', dir=ROOT / '.build/validation')
        cls.cwd = Path(cls.temporary.name)
        (cls.cwd/'relative-data.txt').write_text('目录正常', encoding='utf-8')
        cls.errors = open(ROOT/'.build/validation/notebook-kernel-stderr.log','w+')
        cls.process = subprocess.Popen([sys.executable,'-u',str(ROOT/'Sources/MarginNotes/Resources/notebook_kernel.py')],
                                       stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=cls.errors,text=True)
        cls.messages = queue.Queue()
        threading.Thread(target=lambda: [cls.messages.put(json.loads(line)) for line in cls.process.stdout], daemon=True).start()
        cls.request('start', kernel='python3', cwd=str(cls.cwd), until='ready')

    @classmethod
    def send(cls, op, **values):
        request = uuid.uuid4().hex
        cls.process.stdin.write(json.dumps(dict(id=request,op=op,**values))+'\n');cls.process.stdin.flush()
        return request

    @classmethod
    def receive(cls, request, until='complete', timeout=45):
        end = time.monotonic()+timeout; found=[]
        while time.monotonic()<end:
            try: item=cls.messages.get(timeout=max(.1,end-time.monotonic()))
            except queue.Empty:
                cls.errors.flush();cls.errors.seek(0)
                raise AssertionError('Kernel timed out: '+cls.errors.read()[-3000:])
            if item.get('id')!=request: continue
            found.append(item)
            if item['event']=='error':
                cls.errors.flush();cls.errors.seek(0)
                raise AssertionError(item['message']+'\n'+cls.errors.read()[-5000:])
            if item['event']==until: return found
        raise AssertionError('No final message')

    @classmethod
    def request(cls, op, until='complete', **values):
        return cls.receive(cls.send(op,**values),until=until)

    @classmethod
    def tearDownClass(cls):
        try:
            cls.request('shutdown',until='stopped');cls.process.wait(timeout=15)
            if cls.process.returncode!=0: raise AssertionError('Bridge did not stop cleanly')
        finally:
            if cls.process.poll() is None: cls.process.kill()
            cls.process.stdin.close();cls.process.stdout.close();cls.errors.close();cls.temporary.cleanup()

    def test_1_kernel_discovery_and_persistent_namespace(self):
        kernels=self.request('list',until='kernels')[-1]['kernels']
        self.assertTrue(any(k['name']=='python3' for k in kernels))
        self.request('execute',code='meaning = 40')
        result=self.request('execute',code='meaning + 2')
        self.assertTrue(any(m.get('type')=='execute_result' and m['content']['data']['text/plain']=='42' for m in result))

    def test_2_streams_errors_and_working_directory(self):
        result=self.request('execute',code="from pathlib import Path\nprint(Path('relative-data.txt').read_text())\nraise ValueError('测试错误')")
        self.assertTrue(any(m.get('type')=='stream' and '目录正常' in m['content']['text'] for m in result))
        self.assertTrue(any(m.get('type')=='error' and m['content']['ename']=='ValueError' for m in result))
        self.assertEqual(result[-1]['status'],'error')

    def test_3_rich_display_and_update(self):
        code="from IPython.display import display, HTML\nh = display(HTML('<b>原输出</b>'), display_id=True)\nh.update(HTML('<b>更新输出</b>'))"
        result=self.request('execute',code=code)
        self.assertTrue(any(m.get('type')=='display_data' and '<b>原输出</b>'==m['content']['data'].get('text/html') for m in result))
        self.assertTrue(any(m.get('type')=='update_display_data' and '<b>更新输出</b>'==m['content']['data'].get('text/html') for m in result))

    def test_4_interrupt_and_restart(self):
        request=self.send('execute',code='import time\nprint("started", flush=True)\ntime.sleep(60)')
        while True:
            m=self.messages.get(timeout=10)
            if m.get('id')==request and m.get('type')=='stream': break
        self.send('interrupt')
        result=self.receive(request,timeout=10)
        self.assertEqual(result[-1]['status'],'error')
        self.request('start',kernel='python3',cwd=str(self.cwd),until='ready')
        result=self.request('execute',code='meaning')
        self.assertTrue(any(m.get('type')=='error' and m['content']['ename']=='NameError' for m in result))


if __name__=='__main__': unittest.main(verbosity=2)
