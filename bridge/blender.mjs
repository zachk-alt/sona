import { spawn } from 'node:child_process';
import { constants } from 'node:fs';
import { access, mkdir, mkdtemp, readFile, readdir, rmdir, stat, unlink } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { BridgeError, fail } from './errors.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const TYPES = ['cube', 'sphere', 'cylinder', 'cone', 'torus', 'plane', 'mesh'];
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const number = (value, min, max) => typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max;
const vec = (value, min, max) => Array.isArray(value) && value.length === 3 && value.every(x => number(x, min, max));
const keys = (value, allowed) => object(value) && Object.keys(value).every(key => allowed.includes(key));

export const BLENDER_SCENE_GUIDE = `Return a declarative scene, never Python, commands, paths or asset URLs.
Scene: {version:1,objects:[...],camera?:{position:[x,y,z],target:[x,y,z],focalLength?:15..120},background?:[r,g,b],lights?:[...]}.
Each object: {type:"cube"|"sphere"|"cylinder"|"cone"|"torus"|"plane"|"mesh",name?:string,position?:[x,y,z],rotation?:[x,y,z],size?:[x,y,z],color?:[r,g,b],metallic?:0..1,roughness?:0..1,bevel?:0..0.25}.
Rotation is Euler degrees. Size is final local XYZ dimensions, applied before rotation; plane Z is ignored. Z points up. Use separate named editable objects, deliberate proportions, colors and a useful camera. A torus has a fixed rounded ring profile. A mesh additionally requires vertices:[[x,y,z],...] and faces:[[index,index,index,...],...]; its size, when omitted, preserves vertex dimensions.
1..96 objects; each mesh 3..4096 vertices and 1..4096 faces; each face 3..8 distinct indices; maximum 20000 total vertices and 20000 total faces. Coordinates -100..100; size .01..100; rotation -360..360; RGB 0..1. Names at most100 characters. No other fields.
Light: {type:"area"|"point"|"sun",position:[x,y,z],target?:[x,y,z],color?:[r,g,b],energy?:0..3000,size?:.1..20}; maximum8. Camera position and target must differ. Omit camera/lights for automatic framing and studio lighting.
Create a useful editable approximation from the reference, acknowledging limits for intricate organic geometry, textures or unseen sides. Never claim a pixel-exact reconstruction.`;

export function validateBlenderScene(value) {
  if (!keys(value, ['version', 'objects', 'camera', 'background', 'lights']) || value.version !== 1 ||
      !Array.isArray(value.objects) || !value.objects.length || value.objects.length > 96) fail('invalid_blender_scene');
  let vertices = 0, faces = 0;
  for (const item of value.objects) {
    if (!keys(item, ['type', 'name', 'position', 'rotation', 'size', 'color', 'metallic', 'roughness', 'bevel', 'vertices', 'faces']) ||
        !TYPES.includes(item.type)) fail('invalid_blender_object');
    if (item.name !== undefined && (typeof item.name !== 'string' || !item.name.trim() || item.name.length > 100 || /[\x00-\x1f\x7f-\x9f]/u.test(item.name))) fail('invalid_blender_name');
    for (const [field, min, max] of [['position', -100, 100], ['rotation', -360, 360], ['size', .01, 100], ['color', 0, 1]]) {
      if (item[field] !== undefined && !vec(item[field], min, max)) fail('invalid_blender_geometry');
    }
    for (const [field, max] of [['metallic', 1], ['roughness', 1], ['bevel', .25]]) {
      if (item[field] !== undefined && !number(item[field], 0, max)) fail('invalid_blender_material');
    }
    if (item.type === 'mesh') {
      if (!Array.isArray(item.vertices) || item.vertices.length < 3 || item.vertices.length > 4096 ||
          item.vertices.some(point => !vec(point, -100, 100)) || !Array.isArray(item.faces) ||
          !item.faces.length || item.faces.length > 4096 || item.faces.some(face => !Array.isArray(face) ||
            face.length < 3 || face.length > 8 || new Set(face).size !== face.length ||
            face.some(index => !Number.isInteger(index) || index < 0 || index >= item.vertices.length))) fail('invalid_blender_mesh');
      vertices += item.vertices.length; faces += item.faces.length;
    } else if (item.vertices !== undefined || item.faces !== undefined) fail('invalid_blender_mesh');
  }
  if (vertices > 20000 || faces > 20000) fail('blender_scene_too_large');
  if (value.background !== undefined && !vec(value.background, 0, 1)) fail('invalid_blender_background');
  if (value.camera !== undefined) {
    const camera = value.camera;
    if (!keys(camera, ['position', 'target', 'focalLength']) || !vec(camera.position, -100, 100) || !vec(camera.target, -100, 100) ||
        Math.hypot(...camera.position.map((n, i) => n - camera.target[i])) < .01 ||
        (camera.focalLength !== undefined && !number(camera.focalLength, 15, 120))) fail('invalid_blender_camera');
  }
  if (value.lights !== undefined && (!Array.isArray(value.lights) || value.lights.length > 8 || value.lights.some(light =>
    !keys(light, ['type', 'position', 'target', 'color', 'energy', 'size']) || !['area', 'point', 'sun'].includes(light.type) ||
    !vec(light.position, -100, 100) || (light.target !== undefined && !vec(light.target, -100, 100)) ||
    (light.color !== undefined && !vec(light.color, 0, 1)) || (light.energy !== undefined && !number(light.energy, 0, 3000)) ||
    (light.size !== undefined && !number(light.size, .1, 20))))) fail('invalid_blender_light');
  if (Buffer.byteLength(JSON.stringify(value)) > 1024 * 1024) fail('blender_scene_too_large');
  return value;
}

export async function resolveBlender(env = process.env, platform = process.platform) {
  const candidates = [];
  if (platform === 'darwin') candidates.push('/Applications/Blender.app/Contents/MacOS/Blender', path.join(homedir(), 'Applications/Blender.app/Contents/MacOS/Blender'));
  if (platform === 'win32') {
    for (const base of [env.ProgramFiles, env['ProgramFiles(x86)']].filter(Boolean)) {
      const directory = path.join(base, 'Blender Foundation');
      try {
        for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => b.name.localeCompare(a.name, undefined, { numeric: true }))) {
          if (entry.isDirectory() && /^Blender \d[\d.]*$/u.test(entry.name)) candidates.push(path.join(directory, entry.name, 'blender.exe'));
        }
      } catch { /* An absent installation is not an error during discovery. */ }
    }
  }
  for (const directory of (env.PATH ?? env.Path ?? '').split(platform === 'win32' ? ';' : ':').filter(Boolean)) {
    candidates.push(path.join(directory, platform === 'win32' ? 'blender.exe' : 'blender'));
  }
  for (const candidate of candidates) {
    try { await access(candidate, platform === 'win32' ? constants.F_OK : constants.X_OK); if ((await stat(candidate)).isFile()) return candidate; } catch { /* Try the next normal installation. */ }
  }
  return null;
}

function outputRoot(env) {
  if (process.platform === 'darwin') return path.join(homedir(), 'Library', 'Application Support', 'Sona', 'Creations');
  if (process.platform === 'win32') return path.join(env.LOCALAPPDATA ?? path.join(homedir(), 'AppData', 'Local'), 'Sona', 'Creations');
  return path.join(homedir(), '.local', 'share', 'sona', 'creations');
}

function stopChild(child, env) {
  if (!child.pid) return;
  if (process.platform === 'win32') {
    const killer = spawn(path.join(env.SystemRoot ?? 'C:\\Windows', 'System32', 'taskkill.exe'), ['/pid', String(child.pid), '/T', '/F'], { shell: false, windowsHide: true, stdio: 'ignore' });
    killer.on('error', () => { try { child.kill('SIGKILL'); } catch {} }); killer.unref();
  } else { try { process.kill(-child.pid, 'SIGKILL'); } catch { try { child.kill('SIGKILL'); } catch {} } }
}

// Callers cannot supply Python, arguments, output paths or existing .blend files.
// Private test injection is available only to direct module tests, not the wire protocol.
export async function createBlenderScene(scene, { env = process.env, signal, timeoutMs = 90000, test = null } = {}) {
  validateBlenderScene(scene);
  if (signal?.aborted) fail('cancelled');
  const executable = test?.executable ?? await resolveBlender(env);
  if (!executable) fail('blender_not_installed');
  const parent = test?.outputRoot ?? outputRoot(env);
  await mkdir(parent, { recursive: true, mode: 0o700 });
  const directory = await mkdtemp(path.join(parent, 'Scene-'));
  const blendPath = path.join(directory, 'Scene.blend'), previewPath = path.join(directory, 'Preview.png');
  const args = ['--background', '--factory-startup', '--disable-autoexec', '--threads', '4', '--python-exit-code', '31',
    '--python', path.join(ROOT, 'blender-scene.py'), '--', blendPath, previewPath];
  const childEnv = { ...env, PYTHONNOUSERSITE: '1' };
  for (const key of Object.keys(childEnv)) if (/^(?:PYTHONPATH|PYTHONHOME|BLENDER_USER_|BLENDER_SYSTEM_)/u.test(key)) delete childEnv[key];
  try {
    await new Promise((resolve, reject) => {
      let done = false, received = 0, tail = '', completed = false;
      const child = spawn(executable, args, { env: childEnv, cwd: directory, shell: false, windowsHide: true,
        detached: process.platform !== 'win32', stdio: ['pipe', 'pipe', 'ignore'] });
      const finish = error => {
        if (done) return; done = true; clearTimeout(timer); signal?.removeEventListener('abort', cancel);
        if (error) stopChild(child, env);
        child.stdin.destroy(); child.stdout.destroy();
        error ? reject(error) : resolve();
      };
      const cancel = () => finish(new BridgeError('cancelled'));
      const timer = setTimeout(() => finish(new BridgeError('blender_timeout')), Math.max(100, Math.min(timeoutMs, 90000)));
      signal?.addEventListener('abort', cancel, { once: true });
      child.on('error', () => finish(new BridgeError('blender_launch_failed')));
      child.stdin.on('error', () => finish(new BridgeError('blender_failed')));
      child.stdout.on('data', chunk => {
        received += chunk.length;
        if (received > 2 * 1024 * 1024) { finish(new BridgeError('blender_output_too_large')); return; }
        tail = (tail + chunk.toString('utf8')).slice(-256);
        if (tail.includes('SONA_BLENDER_DONE')) completed = true;
      });
      child.on('close', code => finish(code === 0 && completed ? null : new BridgeError('blender_failed')));
      if (signal?.aborted) { cancel(); return; }
      child.stdin.end(JSON.stringify(scene));
    });
    const [blend, preview] = await Promise.all([stat(blendPath), stat(previewPath)]);
    if (!blend.isFile() || blend.size < 12 || blend.size > 64 * 1024 * 1024 || !preview.isFile() || preview.size < 16 || preview.size > 16 * 1024 * 1024) fail('invalid_blender_artifact');
    const bytes = await readFile(previewPath);
    if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) fail('invalid_blender_artifact');
    return { blendPath, previewPath };
  } catch (error) {
    // Remove only fixed filenames in this newly created directory, never recurse.
    for (const name of ['Scene.blend', 'Scene.blend1', 'Preview.png']) {
      try { await unlink(path.join(directory, name)); } catch { /* Preserve unknown files. */ }
    }
    try { await rmdir(directory); } catch { /* Never remove unknown content. */ }
    throw error;
  }
}
