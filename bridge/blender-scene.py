"""Fixed scene builder. Input is bounded, validated geometry JSON, never code."""
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def point_at(obj, target):
    direction = Vector(target) - obj.location
    if direction.length > 0.001:
        obj.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()


def build():
    raw = sys.stdin.buffer.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise ValueError('input bound')
    spec = json.loads(raw)
    # The Node boundary validates every field before launching this fixed script.
    if spec.get('version') != 1 or not 1 <= len(spec['objects']) <= 96:
        raise ValueError('invalid scene')
    args = sys.argv[sys.argv.index('--') + 1:]
    if len(args) != 2:
        raise ValueError('output arguments')
    blend, preview = map(Path, args)
    if blend.exists() or preview.exists() or blend.name != 'Scene.blend' or preview.name != 'Preview.png' or blend.parent != preview.parent:
        raise ValueError('output collision')
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    objects = []
    for index, item in enumerate(spec['objects']):
        kind = item['type']
        if kind == 'cube':
            bpy.ops.mesh.primitive_cube_add(size=1)
        elif kind == 'sphere':
            bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=0.5)
        elif kind == 'cylinder':
            bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=0.5, depth=1)
        elif kind == 'cone':
            bpy.ops.mesh.primitive_cone_add(vertices=48, radius1=0.5, radius2=0, depth=1)
        elif kind == 'torus':
            bpy.ops.mesh.primitive_torus_add(major_segments=48, minor_segments=16, major_radius=0.38, minor_radius=0.12)
        elif kind == 'plane':
            bpy.ops.mesh.primitive_plane_add(size=1)
        elif kind == 'mesh':
            mesh = bpy.data.meshes.new('Geometry')
            mesh.from_pydata(item['vertices'], [], item['faces'])
            mesh.update()
            obj = bpy.data.objects.new('Mesh', mesh)
            bpy.context.collection.objects.link(obj)
            bpy.context.view_layer.objects.active = obj
            obj.select_set(True)
        else:
            raise ValueError('unsupported geometry')
        obj = bpy.context.object
        obj.name = item.get('name', f'{kind.title()} {index + 1}')
        if kind != 'mesh' or 'size' in item:
            dims = item.get('size', [1, 1, 1])
            obj.dimensions = (dims[0], dims[1], 0 if kind == 'plane' else dims[2])
            bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        obj.location = item.get('position', [0, 0, 0])
        obj.rotation_euler = [math.radians(x) for x in item.get('rotation', [0, 0, 0])]
        color = item.get('color', [0.72, 0.76, 0.82])
        material = bpy.data.materials.new(f'Material {index + 1}')
        material.diffuse_color = (*color, 1)
        material.use_nodes = True
        surface = material.node_tree.nodes.get('Principled BSDF')
        surface.inputs['Base Color'].default_value = (*color, 1)
        surface.inputs['Metallic'].default_value = item.get('metallic', 0)
        surface.inputs['Roughness'].default_value = item.get('roughness', 0.4)
        obj.data.materials.append(material)
        bevel = item.get('bevel', 0)
        if bevel and kind in ('cube', 'cylinder', 'cone', 'mesh'):
            modifier = obj.modifiers.new('Soft edges', 'BEVEL')
            modifier.width = bevel
            modifier.segments = 3
        if kind in ('sphere', 'cylinder', 'cone', 'torus'):
            for polygon in obj.data.polygons:
                polygon.use_smooth = True
        objects.append(obj)
        obj.select_set(False)
    bpy.context.view_layer.update()
    corners = [obj.matrix_world @ Vector(corner) for obj in objects for corner in obj.bound_box]
    low = Vector([min(p[i] for p in corners) for i in range(3)])
    high = Vector([max(p[i] for p in corners) for i in range(3)])
    center = (low + high) / 2
    extent = max(1.0, (high - low).length)
    camera_spec = spec.get('camera', {})
    camera_data = bpy.data.cameras.new('Camera')
    camera = bpy.data.objects.new('Camera', camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = camera_spec.get('position', center + Vector([1.05, -1.5, 0.95]) * extent)
    camera_data.lens = camera_spec.get('focalLength', 50)
    camera_data.clip_end = 1000
    point_at(camera, camera_spec.get('target', center))
    scene = bpy.context.scene
    scene.camera = camera
    lights = spec.get('lights') or [
        {'type': 'area', 'position': center + Vector([0.8, -1, 1.5]) * extent, 'energy': min(3000, 300 * extent), 'size': min(20, extent)},
        {'type': 'area', 'position': center + Vector([-1, -0.3, 0.7]) * extent, 'energy': min(2000, 140 * extent), 'size': min(20, extent)},
        {'type': 'area', 'position': center + Vector([0.4, 1, 1]) * extent, 'energy': min(2500, 200 * extent), 'size': min(20, extent * 0.7)},
    ]
    for index, item in enumerate(lights):
        data = bpy.data.lights.new(f'Light {index + 1}', item['type'].upper())
        data.energy = item.get('energy', 2 if item['type'] == 'sun' else 500)
        data.color = item.get('color', [1, 1, 1])
        if item['type'] == 'area':
            data.shape = 'DISK'
            data.size = item.get('size', 5)
        light = bpy.data.objects.new(data.name, data)
        bpy.context.collection.objects.link(light)
        light.location = item['position']
        point_at(light, item.get('target', center))
    world = bpy.data.worlds.new('Sona World')
    world.use_nodes = True
    background = world.node_tree.nodes.get('Background')
    background.inputs['Color'].default_value = (*spec.get('background', [0.045, 0.055, 0.075]), 1)
    background.inputs['Strength'].default_value = 0.5
    scene.world = world
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = 24
    scene.cycles.use_denoising = True
    scene.render.resolution_x = 768
    scene.render.resolution_y = 768
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.filepath = str(preview)
    scene.render.film_transparent = False
    # Open the saved scene in camera view, with editable geometry selected.
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == 'VIEW_3D':
                area.spaces.active.region_3d.view_perspective = 'CAMERA'
                area.spaces.active.shading.color_type = 'MATERIAL'
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(blend), check_existing=False)
    bpy.ops.render.render(write_still=True)
    print('SONA_BLENDER_DONE', flush=True)


try:
    build()
except Exception:
    print('SONA_BLENDER_ERROR', flush=True)
    sys.exit(31)
