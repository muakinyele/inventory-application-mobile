import { useEffect, useRef, useState } from 'react'
import { Sheet } from './Sheet'

interface DetectedBarcode {
  rawValue: string
}

interface BarcodeDetectorLike {
  detect: (source: CanvasImageSource) => Promise<DetectedBarcode[]>
}

type BarcodeDetectorCtor = new (options?: { formats?: string[] }) => BarcodeDetectorLike

function getDetectorCtor(): BarcodeDetectorCtor | null {
  const ctor = (globalThis as { BarcodeDetector?: BarcodeDetectorCtor }).BarcodeDetector
  return typeof ctor === 'function' ? ctor : null
}

function barcodeScanningSupported(): boolean {
  return getDetectorCtor() !== null && typeof navigator?.mediaDevices?.getUserMedia === 'function'
}

interface Props {
  open: boolean
  onClose: () => void
  onDetect: (code: string) => void
}

/**
 * Camera barcode scanner built on the native BarcodeDetector API. Where that
 * API is missing (Firefox, desktop Safari) it falls back to typing the code.
 */
export function Scanner({ open, onClose, onDetect }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const [error, setError] = useState<string | null>(null)
  const [manual, setManual] = useState('')
  const supported = barcodeScanningSupported()

  useEffect(() => {
    if (!open || !supported) return

    let stream: MediaStream | null = null
    let frame = 0
    let stopped = false
    const detector = new (getDetectorCtor() as BarcodeDetectorCtor)({
      formats: ['ean_13', 'ean_8', 'code_128', 'code_39', 'upc_a', 'upc_e', 'qr_code'],
    })

    const scan = async () => {
      const video = videoRef.current
      if (stopped || !video || video.readyState < 2) {
        frame = requestAnimationFrame(scan)
        return
      }
      try {
        const codes = await detector.detect(video)
        if (codes.length > 0 && codes[0].rawValue) {
          navigator.vibrate?.(40)
          onDetect(codes[0].rawValue)
          return
        }
      } catch {
        // A single failed frame is normal (e.g. mid-resize); keep scanning.
      }
      frame = requestAnimationFrame(scan)
    }

    navigator.mediaDevices
      .getUserMedia({ video: { facingMode: 'environment' } })
      .then((s) => {
        if (stopped) {
          s.getTracks().forEach((t) => t.stop())
          return
        }
        stream = s
        if (videoRef.current) {
          videoRef.current.srcObject = s
          void videoRef.current.play()
        }
        frame = requestAnimationFrame(scan)
      })
      .catch(() => setError('Camera access was blocked. Enter the code by hand instead.'))

    return () => {
      stopped = true
      cancelAnimationFrame(frame)
      stream?.getTracks().forEach((t) => t.stop())
    }
  }, [open, supported, onDetect])

  const submitManual = () => {
    const code = manual.trim()
    if (!code) return
    setManual('')
    onDetect(code)
  }

  return (
    <Sheet open={open} title="Scan barcode" onClose={onClose}>
      {supported && !error ? (
        <div className="scanner">
          <video ref={videoRef} playsInline muted className="scanner-video" />
          <div className="scanner-frame" />
          <p className="scanner-hint">Point the camera at a barcode.</p>
        </div>
      ) : (
        <p className="muted">
          {error ?? 'This browser has no built-in barcode camera. Type or paste the code instead.'}
        </p>
      )}

      <div className="field">
        <label htmlFor="manual-barcode">Enter code manually</label>
        <div className="row-gap">
          <input
            id="manual-barcode"
            value={manual}
            inputMode="numeric"
            placeholder="e.g. 8801234567890"
            onChange={(e) => setManual(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') submitManual()
            }}
          />
          <button type="button" className="button" onClick={submitManual} disabled={!manual.trim()}>
            Use
          </button>
        </div>
      </div>
    </Sheet>
  )
}
