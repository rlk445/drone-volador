"""
Drone VR - envia a tela do PC para o app Drone VR no iPhone.

Uso:
    python pc_stream.py --ip IP_DO_IPHONE

Opcoes uteis:
    --width 1280 --height 720   resolucao enviada (menor = menos atraso)
    --fps 60                    quadros por segundo
    --quality 70                qualidade JPEG (50-85)
    --monitor 0                 qual monitor (0 = principal)
"""
import argparse
import socket
import struct
import sys
import threading
import time

import cv2
import numpy as np

PORT = 5600

ap = argparse.ArgumentParser()
ap.add_argument("--ip", required=True, help="IP que aparece no app do iPhone")
ap.add_argument("--port", type=int, default=PORT)
ap.add_argument("--width", type=int, default=1280)
ap.add_argument("--height", type=int, default=720)
ap.add_argument("--fps", type=int, default=60)
ap.add_argument("--quality", type=int, default=70)
ap.add_argument("--monitor", type=int, default=0)
args = ap.parse_args()


def make_grabber():
    """Tenta dxcam (rapido, DXGI); se falhar usa mss."""
    try:
        import dxcam
        cam = dxcam.create(output_idx=args.monitor, output_color="BGR")
        cam.start(target_fps=args.fps, video_mode=True)

        def grab():
            return cam.get_latest_frame()

        print("[captura] dxcam")
        return grab
    except Exception as e:
        print(f"[captura] dxcam indisponivel ({e}); usando mss")

    import mss
    sct = mss.mss()
    idx = args.monitor + 1
    if idx >= len(sct.monitors):
        idx = 1
    mon = sct.monitors[idx]

    def grab():
        img = np.array(sct.grab(mon))
        return cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)

    print("[captura] mss")
    return grab


class Slot:
    """Guarda so o quadro mais novo (quadros velhos sao descartados)."""

    def __init__(self):
        self.cv = threading.Condition()
        self.data = None
        self.seq = 0

    def put(self, d):
        with self.cv:
            self.data = d
            self.seq += 1
            self.cv.notify_all()

    def get(self, last_seq, timeout=1.0):
        with self.cv:
            self.cv.wait_for(lambda: self.seq != last_seq, timeout)
            return self.data, self.seq


slot = Slot()


def capture_loop():
    grab = make_grabber()
    period = 1.0 / args.fps
    enc = [int(cv2.IMWRITE_JPEG_QUALITY), args.quality]
    next_t = time.perf_counter()
    while True:
        frame = grab()
        if frame is None:
            time.sleep(0.002)
            continue
        if frame.shape[1] != args.width or frame.shape[0] != args.height:
            frame = cv2.resize(frame, (args.width, args.height),
                               interpolation=cv2.INTER_LINEAR)
        ok, buf = cv2.imencode(".jpg", frame, enc)
        if ok:
            slot.put(buf.tobytes())
        next_t += period
        delay = next_t - time.perf_counter()
        if delay > 0:
            time.sleep(delay)
        else:
            next_t = time.perf_counter()


def connect():
    s = socket.create_connection((args.ip, args.port), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 128 * 1024)
    s.settimeout(None)
    return s


def main():
    threading.Thread(target=capture_loop, daemon=True).start()
    while True:
        try:
            sock = connect()
        except OSError as e:
            print(f"Nao conectou em {args.ip}:{args.port} ({e}). "
                  f"Abra o app Drone VR no iPhone e confira o IP. Tentando de novo...")
            time.sleep(2)
            continue
        print("Conectado! Enviando a tela...")
        last = 0
        sent = 0
        nbytes = 0
        t0 = time.perf_counter()
        try:
            while True:
                data, seq = slot.get(last)
                if data is None or seq == last:
                    continue
                last = seq
                sock.sendall(struct.pack(">I", len(data)) + data)
                sent += 1
                nbytes += len(data)
                now = time.perf_counter()
                if now - t0 >= 2.0:
                    print(f"{sent / (now - t0):.0f} fps | "
                          f"{nbytes / sent / 1024:.0f} KB/quadro")
                    sent = 0
                    nbytes = 0
                    t0 = now
        except OSError as e:
            print(f"Conexao perdida ({e}). Reconectando...")
            try:
                sock.close()
            except OSError:
                pass
            time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
