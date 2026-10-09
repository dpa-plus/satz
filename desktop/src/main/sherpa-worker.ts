import { serve } from './helper'
import { SherpaEngine } from './sherpaEngine'

/** satz's helper process for sherpa-onnx, apart from Whisper's: the two ONNX Runtimes must not meet (sherpaEngine.ts). */
serve((dir, log, setState) => new SherpaEngine(dir, log, setState))
