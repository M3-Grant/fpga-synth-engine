// ============================================================================
//  main.js —— Electron 主进程
//
//  职责：
//    1. 自己打开 CH340 串口（921600），不依赖 Python 桥接
//    2. 起一个只监听 127.0.0.1 的小型 HTTP 服务，把串口字节流转发给渲染进程
//    3. 创建窗口加载 renderer/index.html
//
//  为什么用本地 HTTP 而不是 IPC：
//    渲染层现成的 UI 代码用 fetch('/stream') 读数据，这样 Electron 版
//    一行都不用改；只要把同一套端点用 Node 实现即可。
// ============================================================================
const { app, BrowserWindow, shell } = require('electron');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { SerialPort } = require('serialport');

const HTTP_PORT = 8099;
const BAUD = 921600;
const ROOT = path.join(__dirname, 'renderer');

// ---------------------------------------------------------------------------
// 安全日志
//   Electron 由外部 shell 启动时，进程退出后 stdout 管道会关闭；此时再往
//  stdout 写就会抛 EPIPE，在无 console 的环境里会弹出"主进程未捕获异常"。
//  所以日志一律写文件，不碰 stdout。
// ---------------------------------------------------------------------------
let LOG_FILE = null;
function logFile() {
  if (LOG_FILE) return LOG_FILE;
  try {
    LOG_FILE = path.join(app.getPath('userData'), 'fpga-synth.log');
  } catch (e) {
    LOG_FILE = path.join(__dirname, 'fpga-synth.log');
  }
  return LOG_FILE;
}
function log(...args) {
  const line = new Date().toISOString() + '  ' +
    args.map((a) => (typeof a === 'string' ? a : String(a))).join(' ');
  try { fs.appendFileSync(logFile(), line + '\n'); } catch (e) { /* ignore */ }
}
// 兜底：任何未捕获异常只记日志，不弹窗、不退出
process.on('uncaughtException', (e) => {
  log('[uncaught]', e && e.stack ? e.stack : String(e));
});
process.on('unhandledRejection', (e) => {
  log('[unhandledRejection]', e && e.stack ? e.stack : String(e));
});

let ser = null;              // serialport 实例
let serName = '';
const clients = new Set();   // 正在读 /stream 的 HTTP 响应对象

// ---------------------------------------------------------------- serial
async function openSerial() {
  let list = [];
  try {
    list = await SerialPort.list();
  } catch (e) {
    log('[serial] list failed:', e.message);
  }
  const isCh340 = (p) => ((p.vendorId || '').toUpperCase() === '1A86')
                      || ((p.friendlyName || '').toUpperCase().includes('CH340'))
                      || ((p.path || '').toUpperCase().includes('CH340'));
  const cand = list.find(isCh340) || list.find((p) => /^COM\d+$/i.test(p.path || ''));
  if (!cand) {
    log('[serial] no usable COM port found:', list.map((p) => p.path).join(','));
    return null;
  }
  return new Promise((resolve) => {
    const p = new SerialPort({ path: cand.path, baudRate: BAUD }, (err) => {
      if (err) {
        log('[serial] open failed:', err.message);
        resolve(null);
        return;
      }
      serName = cand.path;
      log('[serial] opened', cand.path, '@', BAUD);
      p.on('data', (d) => {
        for (const res of clients) {
          try { res.write(d); } catch (e) { /* client gone */ }
        }
      });
      p.on('error', (e) => log('[serial] error:', e.message));
      resolve(p);
    });
  });
}

// ---------------------------------------------------------------- http
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.bin': 'application/octet-stream',
  '.png': 'image/png',
  '.json': 'application/json; charset=utf-8',
};

function serveStatic(req, res, urlPath) {
  // 只允许 ROOT 下的文件，防目录穿越
  const rel = urlPath === '/' ? 'index.html' : decodeURIComponent(urlPath).replace(/^\/+/, '');
  const full = path.resolve(ROOT, rel);
  if (!full.startsWith(path.resolve(ROOT))) {
    res.writeHead(403);
    res.end('forbidden');
    return;
  }
  fs.readFile(full, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end('not found');
      return;
    }
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(full).toLowerCase()] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    res.end(data);
  });
}

const server = http.createServer((req, res) => {
  const urlPath = (req.url || '/').split('?')[0];

  if (urlPath === '/info') {
    const body = JSON.stringify({
      serial_name: serName,
      serial_ok: !!(ser && ser.isOpen),
      clients: clients.size,
      pyserial: false,
      electron: true,
    });
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(body);
    return;
  }

  if (urlPath === '/stream') {
    if (!ser || !ser.isOpen) {
      res.writeHead(503, { 'Content-Type': 'text/plain' });
      res.end('serial not connected');
      return;
    }
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Cache-Control': 'no-store',
      Connection: 'keep-alive',
    });
    clients.add(res);
    log('[stream] client connected (' + clients.size + ')');
    res.on('close', () => {
      clients.delete(res);
      log('[stream] client gone (' + clients.size + ')');
    });
    return;
  }

  if (urlPath === '/cmd' && req.method === 'POST') {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const buf = Buffer.concat(chunks);
      let ok = false, error = 'serial not connected';
      if (ser && ser.isOpen && buf.length) {
        try {
          ser.write(buf);
          ok = true;
          error = '';
          log('[cmd] wrote', buf.length, 'bytes:', buf.toString('hex'));
        } catch (e) {
          error = e.message;
        }
      }
      res.writeHead(ok ? 200 : 503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok, wrote: buf.length, error }));
    });
    return;
  }

  serveStatic(req, res, urlPath);
});

// ---------------------------------------------------------------- window
let win = null;

function createWindow() {
  win = new BrowserWindow({
    width: 1474,
    height: 739,
    minWidth: 900,
    minHeight: 560,
    backgroundColor: '#0d0d10',
    autoHideMenuBar: true,
    title: '十二键电子琴 · Tang Nano 20K · 实时可视化',
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
    },
  });
  win.loadURL(`http://127.0.0.1:${HTTP_PORT}/index.html?auto=1`);
  // 外部链接用系统浏览器打开
  win.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });
}

app.whenReady().then(async () => {
  ser = await openSerial();          // 必须接住返回值，否则 ser 一直是 null
  server.listen(HTTP_PORT, '127.0.0.1', () => {
    log('[http] listening on http://127.0.0.1:' + HTTP_PORT);
  });
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  for (const res of clients) { try { res.end(); } catch (e) {} }
  if (ser && ser.isOpen) { try { ser.close(); } catch (e) {} }
  try { server.close(); } catch (e) {}
  if (process.platform !== 'darwin') app.quit();
});
