import { useState, useRef, useCallback, useEffect } from 'react';
import { GoogleGenAI, LiveServerMessage, Modality } from '@google/genai';
import { ConnectionState, LogMessage, VolumeData } from '../types';
import { createAudioBlob, base64ToUint8Array, pcmToAudioBuffer, calculateRMS } from '../utils/audioUtils';

// Model Configuration
const MODEL_NAME = 'gemini-2.5-flash-native-audio-preview-12-2025';
const SYSTEM_INSTRUCTION = `You are a real-time English to Korean interpreter.

RULES:
1. Translate English speech to natural Korean immediately.
2. Do NOT explain - just translate.
3. Keep translations concise.
`;

export const useLiveSession = () => {
  const [status, setStatus] = useState<ConnectionState>(ConnectionState.DISCONNECTED);
  const [logs, setLogs] = useState<LogMessage[]>([]);
  const [volume, setVolume] = useState<VolumeData>({ input: 0, output: 0 });
  const [isMicMuted, setIsMicMuted] = useState(false);

  // Refs for audio contexts and session to avoid stale closures and re-renders
  const inputContextRef = useRef<AudioContext | null>(null);
  const outputContextRef = useRef<AudioContext | null>(null);
  const sessionRef = useRef<any>(null); // Type 'any' used because Session type isn't fully exported in all SDK versions
  const streamRef = useRef<MediaStream | null>(null);
  const processorRef = useRef<ScriptProcessorNode | null>(null);
  
  // Audio Playback Scheduling
  const nextStartTimeRef = useRef<number>(0);
  const sourcesRef = useRef<Set<AudioBufferSourceNode>>(new Set());

  const addLog = useCallback((text: string, sender: LogMessage['sender'], isThought = false) => {
    setLogs((prev) => [
      ...prev,
      {
        id: Math.random().toString(36).substring(7),
        timestamp: new Date(),
        sender,
        text,
        isThought,
      },
    ]);
  }, []);

  const cleanup = useCallback(() => {
    console.log('Cleaning up session...');
    
    // Stop Input
    if (streamRef.current) {
      streamRef.current.getTracks().forEach(track => track.stop());
      streamRef.current = null;
    }
    if (processorRef.current) {
      processorRef.current.disconnect();
      processorRef.current = null;
    }
    if (inputContextRef.current) {
      inputContextRef.current.close();
      inputContextRef.current = null;
    }

    // Stop Output
    sourcesRef.current.forEach(source => {
      try { source.stop(); } catch (e) {}
    });
    sourcesRef.current.clear();
    if (outputContextRef.current) {
      outputContextRef.current.close();
      outputContextRef.current = null;
    }

    // Close Session
    // Note: The SDK doesn't explicitly expose a synchronous .close() on the session object sometimes,
    // but usually responding to 'onclose' or just dropping the reference is enough if the socket closes.
    // Ideally we would call sessionRef.current.close() if available.
    sessionRef.current = null;

    setStatus(ConnectionState.DISCONNECTED);
    setVolume({ input: 0, output: 0 });
  }, []);

  const connect = useCallback(async () => {
    if (!process.env.API_KEY) {
      addLog('API Key not found in environment', 'system');
      return;
    }

    try {
      setStatus(ConnectionState.CONNECTING);
      addLog('Initializing audio devices...', 'system');

      // 1. Setup Input Audio (Microphone -> 16kHz)
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      streamRef.current = stream;
      
      const inputCtx = new (window.AudioContext || (window as any).webkitAudioContext)({ sampleRate: 16000 });
      inputContextRef.current = inputCtx;
      
      const source = inputCtx.createMediaStreamSource(stream);
      const processor = inputCtx.createScriptProcessor(4096, 1, 1);
      processorRef.current = processor;

      source.connect(processor);
      processor.connect(inputCtx.destination);

      // 2. Setup Output Audio (Speaker -> 24kHz)
      const outputCtx = new (window.AudioContext || (window as any).webkitAudioContext)({ sampleRate: 24000 });
      outputContextRef.current = outputCtx;
      nextStartTimeRef.current = outputCtx.currentTime;

      // 3. Initialize Gemini Client
      addLog(`Connecting to ${MODEL_NAME}...`, 'system');
      const client = new GoogleGenAI({ apiKey: process.env.API_KEY });
      
      const sessionPromise = client.live.connect({
        model: MODEL_NAME,
        config: {
          responseModalities: [Modality.AUDIO],
          speechConfig: {
            voiceConfig: { prebuiltVoiceConfig: { voiceName: 'Kore' } },
          },
          systemInstruction: SYSTEM_INSTRUCTION,
        },
        callbacks: {
          onopen: () => {
            setStatus(ConnectionState.CONNECTED);
            addLog('Connected to Gemini Live!', 'system');
            
            // Start processing audio input only after connection is open
            processor.onaudioprocess = (e) => {
              if (isMicMuted) return; // Mute logic

              const inputData = e.inputBuffer.getChannelData(0);
              
              // Visualization input volume
              const vol = calculateRMS(inputData);
              setVolume(prev => ({ ...prev, input: vol }));

              // Send to API
              const blob = createAudioBlob(inputData);
              sessionPromise.then(session => {
                session.sendRealtimeInput({ media: blob });
              });
            };
          },
          onmessage: async (msg: LiveServerMessage) => {
            // 1. Handle Audio Response
            const audioData = msg.serverContent?.modelTurn?.parts?.[0]?.inlineData?.data;
            if (audioData) {
              const pcmBytes = base64ToUint8Array(audioData);
              const audioBuffer = pcmToAudioBuffer(pcmBytes, outputCtx);
              
              // Visualize output volume (approximate from buffer)
              const outputData = audioBuffer.getChannelData(0);
              setVolume(prev => ({ ...prev, output: calculateRMS(outputData) }));

              // Schedule playback
              const source = outputCtx.createBufferSource();
              source.buffer = audioBuffer;
              source.connect(outputCtx.destination);
              
              // Ensure gapless playback
              const currentTime = outputCtx.currentTime;
              const startTime = Math.max(currentTime, nextStartTimeRef.current);
              source.start(startTime);
              
              nextStartTimeRef.current = startTime + audioBuffer.duration;
              
              sourcesRef.current.add(source);
              source.onended = () => {
                sourcesRef.current.delete(source);
                // Reset volume visualization when idle
                if (sourcesRef.current.size === 0) {
                   setVolume(prev => ({ ...prev, output: 0 }));
                }
              };
            }

            // 2. Handle Text Response (Logs)
            const parts = msg.serverContent?.modelTurn?.parts;
            if (parts) {
              for (const part of parts) {
                // Check if it's a "thought" (requires type checking or heuristic)
                const isThought = (part as any).thought === true;
                if (part.text) {
                  if (isThought) {
                    // console.debug('Skipping thought:', part.text); 
                  } else {
                    addLog(part.text, 'model');
                  }
                }
              }
            }

            // 3. Handle Interruption
            if (msg.serverContent?.interrupted) {
              addLog('Interrupted', 'system');
              sourcesRef.current.forEach(s => s.stop());
              sourcesRef.current.clear();
              nextStartTimeRef.current = outputCtx.currentTime;
            }
          },
          onclose: () => {
            addLog('Session closed by server', 'system');
            cleanup();
          },
          onerror: (err) => {
            console.error(err);
            addLog('Error occurred', 'system');
            cleanup();
          }
        }
      });

      // Save session reference (promise wrapper)
      sessionRef.current = sessionPromise;

    } catch (error: any) {
      console.error("Connection Failed", error);
      addLog(`Connection failed: ${error.message}`, 'system');
      cleanup();
    }
  }, [addLog, cleanup, isMicMuted]);

  // Handle Mute Toggle independently
  const toggleMute = useCallback(() => {
    setIsMicMuted(prev => !prev);
  }, []);

  return {
    status,
    connect,
    disconnect: cleanup,
    logs,
    volume,
    isMicMuted,
    toggleMute
  };
};
