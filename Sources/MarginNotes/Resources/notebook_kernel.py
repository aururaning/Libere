"""Local Jupyter bridge. Python uses an isolated helper process with in-process Jupyter channels; no listening socket."""
import json
import os
import queue
import signal
import sys
import tempfile
import threading
import time
from pathlib import Path

commands = queue.Queue()
manager = client = None
running = True
inprocess = False
executing = threading.Event()
protocol_output = sys.stdout
protocol_lock = threading.Lock()


def emit(request, event, **values):
    with protocol_lock:
        protocol_output.write(json.dumps(dict(id=request, event=event, **values), ensure_ascii=False) + '\n')
        protocol_output.flush()


def read_commands():
    try:
        for line in sys.stdin:
            try:
                command = json.loads(line)
                if inprocess and executing.is_set() and command.get('op') in ('interrupt', 'shutdown'):
                    if command['op'] == 'shutdown': commands.put(command)
                    os.kill(os.getpid(), signal.SIGINT)
                    emit(command.get('id',''), 'interrupted')
                else: commands.put(command)
            except Exception as error:
                emit('', 'error', message=str(error))
    finally:
        commands.put({'op': 'shutdown', 'id': 'eof'})


def stop():
    global manager, client
    if client is not None:
        client.stop_channels()
        client = None
    if manager is not None:
        try:
            if inprocess:
                manager.kernel.shell.reset(new_session=True)
                manager.shutdown_kernel()
            else: manager.shutdown_kernel(now=True)
        finally:
            manager = None


def control(command):
    global running
    request = command.get('id', '')
    if command.get('op') == 'interrupt':
        if manager is not None and not inprocess:
            manager.interrupt_kernel()
        emit(request, 'interrupted')
    elif command.get('op') == 'shutdown':
        running = False
        if manager is not None and not inprocess:
            manager.interrupt_kernel()
        emit(request, 'stopped')
    else:
        emit(request, 'error', message='内核正在执行，请先中断或等待完成。')


def execute(command):
    request = command['id']
    if client is None:
        emit(request, 'error', message='请先启动内核。')
        return
    if inprocess:
        execute_local(command)
        return
    msg_id = client.execute(command['code'], allow_stdin=False, stop_on_error=True)
    idle = reply = False
    status = 'ok'
    while running and not (idle and reply):
        while not commands.empty():
            control(commands.get_nowait())
        if not running:
            break
        try:
            msg = client.get_iopub_msg(timeout=0.1)
            if msg.get('parent_header', {}).get('msg_id') == msg_id:
                kind, content = msg['header']['msg_type'], msg['content']
                emit(request, 'message', type=kind, content=content)
                if kind == 'status' and content.get('execution_state') == 'idle':
                    idle = True
        except queue.Empty:
            pass
        try:
            msg = client.get_shell_msg(timeout=0)
            if msg.get('parent_header', {}).get('msg_id') == msg_id:
                reply = True
                status = msg['content'].get('status', 'error')
                emit(request, 'message', type='execute_reply', content=msg['content'])
        except queue.Empty:
            pass
        if manager is not None and not manager.is_alive():
            emit(request, 'error', message='内核已退出。已收到的输出仍保留。')
            return
    emit(request, 'complete', status=status if running else 'aborted')


def execute_local(command):
    request = command['id']
    idle = threading.Event()
    parent = [None]
    def forward():
        while not idle.is_set():
            try: message = client.get_iopub_msg(timeout=0.1)
            except queue.Empty: continue
            kind, content = message['header']['msg_type'], message['content']
            message_parent = message.get('parent_header',{}).get('msg_id')
            if kind == 'execute_input': parent[0] = message_parent
            if parent[0] is not None and message_parent != parent[0]: continue
            emit(request, 'message', type=kind, content=content)
            if kind == 'status' and content.get('execution_state') == 'idle': idle.set()
    pump = threading.Thread(target=forward, daemon=True)
    executing.set(); pump.start()
    try:
        msg_id = client.execute(command['code'], allow_stdin=False)
        reply = client.get_shell_msg(timeout=10)
        while reply.get('parent_header',{}).get('msg_id') != msg_id:
            reply = client.get_shell_msg(timeout=10)
        idle.wait(timeout=10)
        emit(request, 'message', type='execute_reply', content=reply['content'])
        emit(request, 'complete', status=reply['content'].get('status','error'))
    finally:
        executing.clear(); idle.set(); pump.join(timeout=1)


def main():
    global manager, client, inprocess
    # Keep generated runtime files in a temporary directory and use private local IPC.
    with tempfile.TemporaryDirectory(prefix='mn-kernel-', dir='/tmp') as temporary:
        os.environ.setdefault('IPYTHONDIR', str(Path(temporary) / 'ipython'))
        os.environ.setdefault('JUPYTER_RUNTIME_DIR', temporary)
        from jupyter_client import KernelManager
        from jupyter_client.kernelspec import KernelSpecManager
        threading.Thread(target=read_commands, daemon=True).start()
        try:
            while running:
                command = commands.get()
                request = command.get('id', '')
                try:
                    op = command.get('op')
                    if op == 'list':
                        specs = KernelSpecManager().get_all_specs()
                        emit(request, 'kernels', kernels=[dict(name=k, title=v['spec']['display_name'], language=v['spec']['language']) for k, v in specs.items()])
                    elif op == 'start':
                        stop()
                        cwd = Path(command['cwd']).resolve(strict=True)
                        if not cwd.is_dir():
                            raise ValueError('工作目录不存在。')
                        inprocess = command.get('kernel', 'python3') == 'python3'
                        if inprocess:
                            from ipykernel.inprocess.manager import InProcessKernelManager
                            from ipykernel.inprocess.ipkernel import InProcessKernel, InProcessInteractiveShell
                            from traitlets.config import Config
                            class NotebookKernel(InProcessKernel):
                                def set_parent(self, ident, parent, channel='shell'):
                                    super().set_parent(ident, parent, channel)
                                    if channel == 'shell':
                                        self.stdout.set_parent(parent)
                                        self.stderr.set_parent(parent)
                            os.chdir(cwd)
                            InProcessInteractiveShell.clear_instance()
                            config = Config(); config.HistoryManager.hist_file = ':memory:'
                            manager = InProcessKernelManager(config=config)
                            manager.kernel = NotebookKernel(parent=manager, session=manager.session, config=config)
                            client = manager.client(); client.start_channels()
                        else:
                            manager = KernelManager(kernel_name=command.get('kernel', 'python3'), transport='ipc',
                                                    ip=str(Path(temporary) / 'socket'), connection_file=str(Path(temporary) / 'kernel.json'))
                            manager.start_kernel(cwd=str(cwd), stdout=sys.stderr, stderr=sys.stderr)
                            client = manager.client(); client.start_channels(); client.wait_for_ready(timeout=30)
                        emit(request, 'ready', kernel=command.get('kernel', 'python3'), cwd=str(cwd))
                    elif op == 'execute':
                        execute(command)
                    elif op in ('interrupt', 'shutdown'):
                        control(command)
                    else:
                        raise ValueError('未知内核命令。')
                except Exception as error:
                    emit(request, 'error', message=str(error))
        finally:
            stop()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        emit('', 'error', message=str(error))
        sys.exit(1)
