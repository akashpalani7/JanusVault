import fs from 'fs';
import path from 'path';

const copyFile = (src, dest) => {
  const destDir = path.dirname(dest);
  fs.mkdirSync(destDir, { recursive: true });
  fs.copyFileSync(src, dest);
};

const copyDir = (src, dest) => {
  fs.mkdirSync(dest, { recursive: true });
  const entries = fs.readdirSync(src, { withFileTypes: true });
  for (let entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
};

try {
  // 1. Ensure output directories exist
  fs.mkdirSync('dist/popup', { recursive: true });
  fs.mkdirSync('dist/icons', { recursive: true });

  // 2. Copy popup HTML & CSS
  copyFile('src/popup/popup.html', 'dist/popup/popup.html');
  copyFile('src/popup/popup.css', 'dist/popup/popup.css');

  // 3. Copy manifest and offscreen HTML
  copyFile('public/manifest.json', 'dist/manifest.json');
  copyFile('src/offscreen/offscreen-ble.html', 'dist/offscreen/offscreen-ble.html');

  // 4. Copy icons
  if (fs.existsSync('public/icons')) {
    copyDir('public/icons', 'dist/icons');
  }

  console.log('Assets copied successfully.');
} catch (err) {
  console.error('Error copying assets:', err);
  process.exit(1);
}
