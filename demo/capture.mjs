// Renders demo.html frame by frame for the README demo (assets/dictator-demo.mp4 and .gif).
// npm i playwright && DSF=1.5 node capture.mjs video 30     stills: node capture.mjs stills 4.6 13.8
// then: ffmpeg -framerate 30 -i frames/f%05d.png -c:v libx264 -crf 20 -pix_fmt yuv420p ../assets/dictator-demo.mp4
import { chromium } from 'playwright';
import { mkdirSync } from 'fs';
const [mode, ...args] = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: Number(process.env.DSF || 1) });
await page.goto('file://' + process.cwd() + '/demo.html');
await page.evaluate(() => document.fonts.ready);
if (mode === 'stills') {
  mkdirSync('stills', { recursive: true });
  for (const t of args) { await page.evaluate(t => render(t), Number(t)); await page.screenshot({ path: `stills/t${t}.png` }); }
} else {
  mkdirSync('frames', { recursive: true });
  const fps = Number(args[0] || 30), dur = await page.evaluate(() => DURATION);
  for (let i = 0; i < Math.round(dur * fps); i++) {
    await page.evaluate(t => render(t), i / fps);
    await page.screenshot({ path: `frames/f${String(i).padStart(5, '0')}.png` });
  }
}
await browser.close();
