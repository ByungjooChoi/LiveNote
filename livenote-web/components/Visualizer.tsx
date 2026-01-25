import React, { useEffect, useRef } from 'react';

interface VisualizerProps {
  inputLevel: number;
  outputLevel: number;
  isActive: boolean;
}

const Visualizer: React.FC<VisualizerProps> = ({ inputLevel, outputLevel, isActive }) => {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    let animationId: number;

    const draw = () => {
      const width = canvas.width;
      const height = canvas.height;
      const midX = width / 2;

      ctx.clearRect(0, 0, width, height);

      // Styling
      ctx.lineCap = 'round';
      const maxBarHeight = height * 0.8;

      // Input Bar (Left - Microphone)
      // Visual scaling: simple log-ish boost for visibility
      const inputH = Math.min(maxBarHeight, (inputLevel * 5) * maxBarHeight);
      
      ctx.fillStyle = isActive ? '#10b981' : '#374151'; // Green-500 or Gray-700
      ctx.fillRect(midX - 20 - 40, (height - inputH) / 2, 40, inputH);

      // Output Bar (Right - AI)
      const outputH = Math.min(maxBarHeight, (outputLevel * 5) * maxBarHeight);
      ctx.fillStyle = isActive ? '#3b82f6' : '#374151'; // Blue-500 or Gray-700
      ctx.fillRect(midX + 20, (height - outputH) / 2, 40, outputH);

      // Labels
      ctx.font = '12px monospace';
      ctx.fillStyle = '#9ca3af'; // Gray-400
      ctx.textAlign = 'center';
      ctx.fillText('MIC', midX - 40, height - 10);
      ctx.fillText('AI', midX + 40, height - 10);

      animationId = requestAnimationFrame(draw);
    };

    draw();

    return () => {
      cancelAnimationFrame(animationId);
    };
  }, [inputLevel, outputLevel, isActive]);

  return (
    <div className="w-full h-48 bg-gray-800 rounded-lg overflow-hidden border border-gray-700 shadow-inner">
      <canvas 
        ref={canvasRef} 
        width={400} 
        height={192} 
        className="w-full h-full"
      />
    </div>
  );
};

export default Visualizer;
