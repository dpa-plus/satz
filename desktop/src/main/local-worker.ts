import { serve } from './helper'
import { WhisperEngine } from './whisperEngine'

/** satz's helper process for Whisper (transformers.js on onnxruntime-node). */
serve((dir, log, setState) => new WhisperEngine(dir, log, setState))
