import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createBlenderScene, validateBlenderScene } from '../blender.mjs';

const scene = () => ({ version: 1, objects: [{ type: 'cube', size: [2, 1, 1], position: [0, 0, .5], color: [.1, .3, .9] }] });

test('scene validator permits editable primitives and bounded mesh geometry', () => {
  const value = scene();
  value.objects.push({ type: 'mesh', vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], faces: [[0, 1, 2]] });
  value.camera = { position: [5, -5, 3], target: [0, 0, 0] };
  assert.equal(validateBlenderScene(value), value);
});

test('scene validator rejects code, paths, external assets and unknown geometry', () => {
  for (const mutation of [
    value => { value.python = 'print(1)'; },
    value => { value.outputPath = '/tmp/existing.blend'; },
    value => { value.objects[0].texture = 'https://example.com/image.png'; },
    value => { value.objects[0].type = 'script'; },
    value => { value.objects[0].name = 'name\ncommand'; },
  ]) { const value = scene(); mutation(value); assert.throws(() => validateBlenderScene(value)); }
});

test('scene validator rejects nonfinite, excessive and degenerate inputs', () => {
  for (const mutation of [
    value => { value.objects[0].position = [Infinity, 0, 0]; },
    value => { value.objects[0].size = [0, 1, 1]; },
    value => { value.objects[0].rotation = [0, 720, 0]; },
    value => { value.objects = Array.from({ length: 97 }, () => ({ type: 'sphere' })); },
    value => { value.camera = { position: [0, 0, 0], target: [0, 0, 0] }; },
    value => { value.objects = [{ type: 'mesh', vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], faces: [[0, 1, 3]] }]; },
    value => { value.objects = [{ type: 'mesh', vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], faces: [[0, 1, 1]] }]; },
  ]) { const value = scene(); mutation(value); assert.throws(() => validateBlenderScene(value)); }
});

test('invalid or cancelled scene never starts a process or creates an output directory', async () => {
  const controller = new AbortController(); controller.abort();
  await assert.rejects(createBlenderScene(scene(), { signal: controller.signal }), /cancelled/);
  await assert.rejects(createBlenderScene({ ...scene(), python: 'bad' }), /invalid_blender_scene/);
});

test('failed Blender launch leaves existing work untouched and removes only its empty creation', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'sona-blender-test-'));
  const existing = path.join(root, 'Existing.blend'); await writeFile(existing, 'keep');
  await assert.rejects(createBlenderScene(scene(), { test: { outputRoot: root, executable: path.join(root, 'missing-blender') } }), /blender_launch_failed/);
  assert.equal(await readFile(existing, 'utf8'), 'keep');
  assert.deepEqual(await readdir(root), ['Existing.blend']);
});
