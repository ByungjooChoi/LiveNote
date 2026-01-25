import React, { useEffect, useRef } from 'react';
import { useLiveSession } from './hooks/useLiveSession';
import Visualizer from './components/Visualizer';
import { ConnectionState } from './types';

const App: React.FC = () => {
  const { 
    status, 
    connect, 
    disconnect, 
    logs, 
    volume, 
    isMicMuted, 
    toggleMute 
  } = useLiveSession();

  const logsEndRef = useRef<HTMLDivElement>(null);

  // Auto-scroll logs
  useEffect(() => {
    logsEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [logs]);

  const isConnected = status === ConnectionState.CONNECTED;
  const isConnecting = status === ConnectionState.CONNECTING;

  return (
    <div className="min-h-screen bg-gray-900 text-gray-100 flex flex-col font-sans">
      {/* Header */}
      <header className="bg-gray-800 border-b border-gray-700 p-4 sticky top-0 z-10 shadow-md">
        <div className="max-w-3xl mx-auto flex items-center justify-between">
          <div className="flex items-center space-x-2">
            <span className="text-2xl">🚀</span>
            <h1 className="text-xl font-bold tracking-tight text-white">LiveNote Web</h1>
            <span className="text-xs px-2 py-0.5 rounded-full bg-blue-900 text-blue-200 border border-blue-700">
              Preview
            </span>
          </div>
          <div className="flex items-center space-x-2">
            <div className={`w-2 h-2 rounded-full ${isConnected ? 'bg-green-500 animate-pulse' : 'bg-red-500'}`}></div>
            <span className="text-sm font-mono text-gray-400">{status}</span>
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="flex-1 max-w-3xl w-full mx-auto p-4 flex flex-col space-y-6">
        
        {/* Visualizer Section */}
        <section>
          <Visualizer 
            inputLevel={volume.input} 
            outputLevel={volume.output} 
            isActive={isConnected}
          />
        </section>

        {/* Logs / Transcript */}
        <section className="flex-1 bg-gray-800 rounded-lg border border-gray-700 flex flex-col overflow-hidden h-[400px]">
          <div className="p-3 bg-gray-750 border-b border-gray-700 text-xs text-gray-400 uppercase tracking-wider font-semibold flex justify-between">
            <span>Live Transcript</span>
            <span>English → Korean</span>
          </div>
          <div className="flex-1 overflow-y-auto p-4 space-y-4 scrollbar-hide">
            {logs.length === 0 && (
              <div className="text-center text-gray-500 mt-10 italic">
                Ready to connect. Speak English, hear Korean.
              </div>
            )}
            {logs.map((log) => (
              <div 
                key={log.id} 
                className={`flex flex-col ${
                  log.sender === 'user' ? 'items-end' : 
                  log.sender === 'system' ? 'items-center' : 'items-start'
                }`}
              >
                <div className={`
                  max-w-[80%] rounded-lg px-4 py-2 text-sm shadow-sm
                  ${log.sender === 'user' ? 'bg-indigo-600 text-white rounded-br-none' : 
                    log.sender === 'system' ? 'bg-gray-700 text-gray-300 text-xs py-1' : 
                    'bg-gray-600 text-white rounded-bl-none'}
                `}>
                  {log.text}
                </div>
                {log.sender !== 'system' && (
                  <span className="text-[10px] text-gray-500 mt-1">
                    {log.sender === 'user' ? 'You' : 'Gemini'}
                  </span>
                )}
              </div>
            ))}
            <div ref={logsEndRef} />
          </div>
        </section>

      </main>

      {/* Sticky Controls */}
      <footer className="bg-gray-800 border-t border-gray-700 p-4 sticky bottom-0 z-20">
        <div className="max-w-3xl mx-auto flex items-center justify-between gap-4">
          
          {/* Mute Toggle */}
          <button
            onClick={toggleMute}
            disabled={!isConnected}
            className={`
              p-3 rounded-full transition-colors flex items-center justify-center
              ${isMicMuted 
                ? 'bg-red-900/50 text-red-400 border border-red-800 hover:bg-red-900' 
                : 'bg-gray-700 text-white hover:bg-gray-600 border border-gray-600'}
              disabled:opacity-50 disabled:cursor-not-allowed
            `}
            title={isMicMuted ? "Unmute Microphone" : "Mute Microphone"}
          >
             {isMicMuted ? (
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor" className="w-6 h-6">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M17.25 9.75 19.5 12m0 0 2.25 2.25M19.5 12l2.25-2.25M19.5 12l-2.25 2.25m-10.5-6 4.72-4.72a.75.75 0 0 1 1.28.53v15.88a.75.75 0 0 1-1.28.53l-4.72-4.72H4.51c-.88 0-1.704-.507-1.938-1.354A9.009 9.009 0 0 1 2.25 12c0-.83.112-1.633.322-2.396C2.806 8.756 3.63 8.25 4.51 8.25H6.75Z" />
                </svg>
             ) : (
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor" className="w-6 h-6">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M19.114 5.636a9 9 0 0 1 0 12.728M16.463 8.288a5.25 5.25 0 0 1 0 7.424M6.75 8.25l4.72-4.72a.75.75 0 0 1 1.28.53v15.88a.75.75 0 0 1-1.28.53l-4.72-4.72H4.51c-.88 0-1.704-.507-1.938-1.354A9.009 9.009 0 0 1 2.25 12c0-.83.112-1.633.322-2.396C2.806 8.756 3.63 8.25 4.51 8.25H6.75Z" />
                </svg>
             )}
          </button>

          {/* Connect / Disconnect Button */}
          {isConnected || isConnecting ? (
             <button
              onClick={disconnect}
              className="flex-1 bg-red-600 hover:bg-red-700 text-white font-bold py-3 px-6 rounded-lg shadow-lg transition-all transform active:scale-95 flex items-center justify-center gap-2"
            >
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor" className="w-5 h-5">
                <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 9V5.25A2.25 2.25 0 0 0 13.5 3h-6a2.25 2.25 0 0 0-2.25 2.25v13.5A2.25 2.25 0 0 0 7.5 21h6a2.25 2.25 0 0 0 2.25-2.25V15m3 0 3-3m0 0-3-3m3 3H9" />
              </svg>
              Disconnect
            </button>
          ) : (
            <button
              onClick={connect}
              className="flex-1 bg-indigo-600 hover:bg-indigo-500 text-white font-bold py-3 px-6 rounded-lg shadow-lg shadow-indigo-500/30 transition-all transform active:scale-95 flex items-center justify-center gap-2"
            >
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor" className="w-5 h-5">
                <path strokeLinecap="round" strokeLinejoin="round" d="M5.636 5.636a9 9 0 1 0 12.728 0M12 3v9" />
              </svg>
              Start Live Translation
            </button>
          )}
        </div>
      </footer>
    </div>
  );
};

export default App;
