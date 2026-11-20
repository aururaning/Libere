#!/usr/bin/env python3
"""Validate actual OpenStep project structure, plist files, source references, schemes.

This is intentionally NOT a Swift compiler or a substitute for check.sh on macOS.
"""
from pathlib import Path
import json
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
raw = (root/'MarginNotes.xcodeproj/project.pbxproj').read_text()
tokens = re.findall(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', raw, re.S)
tokens = [t for t in tokens if not t.startswith('//') and not t.startswith('/*')]
pos = 0
def take():
    global pos
    t = tokens[pos]; pos += 1; return t
def expect(t):
    found = take(); assert found == t, (t, found, pos)
def value():
    token = take()
    if token == '{':
        result = {}
        while tokens[pos] != '}':
            key = value(); expect('='); result[key] = value(); expect(';')
        expect('}'); return result
    if token == '(':
        result = []
        while tokens[pos] != ')':
            result.append(value())
            if tokens[pos] == ',': expect(',')
            else: assert tokens[pos] == ')'
        expect(')'); return result
    return json.loads(token) if token.startswith('"') else token
project = value(); assert pos == len(tokens)
objects = project['objects']; assert objects[project['rootObject']]['isa'] == 'PBXProject'
for path in (root/'Config').iterdir():
    if path.suffix in ['.plist','.entitlements']:
        with path.open('rb') as f: assert isinstance(plistlib.load(f), dict)
phases = [o for o in objects.values() if o['isa'] == 'PBXSourcesBuildPhase']
assert len(phases) == 1
compiled = []
for build_id in phases[0]['files']:
    file_ref = objects[objects[build_id]['fileRef']]
    path = root/file_ref['path']; assert path.is_file(), path
    compiled.append(file_ref['path'])
expected = sorted(str(p.relative_to(root)) for p in root.glob('Sources/**/*.swift'))
assert sorted(compiled) == expected
assert len(compiled) == len(set(compiled))
resource_phases = [o for o in objects.values() if o['isa'] == 'PBXResourcesBuildPhase']
assert len(resource_phases) == 1
resources = [objects[objects[item]['fileRef']]['path'] for item in resource_phases[0]['files']]
assert resources.count('Sources/MarginNotes/Resources/notebook_kernel.py') == 1
assert resources.count('Sources/MarginNotes/Resources/BrandLogo.png') == 1
assert resources.count('Sources/MarginNotes/Resources/Assets.xcassets') == 1
for name in ('libere_agent.py','agent_rules.md','agent_tools.json','agent_openapi.json','Showcase.json'):
    assert resources.count('Sources/MarginNotes/Resources/' + name) == 1
assert all((root/path).exists() for path in resources)
icons = root/'Sources/MarginNotes/Resources/Assets.xcassets/AppIcon.appiconset'
for icon in json.loads((icons/'Contents.json').read_text())['images']:
    png = (icons/icon['filename']).read_bytes()
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    scale = int(icon['scale'][0])
    expected_size = tuple(int(float(n)*scale) for n in icon['size'].split('x'))
    assert struct.unpack('>II', png[16:24]) == expected_size, icon['filename']
refs = ['mainGroup','productRefGroup','productReference','buildConfigurationList','fileRef','baseConfigurationReference']
arrays = ['children','targets','buildPhases','buildConfigurations','files']
for obj in objects.values():
    for key in refs:
        if key in obj: assert obj[key] in objects, (key, obj[key])
    for key in arrays:
        for ref in obj.get(key,[]): assert ref in objects, (key, ref)
schemes = sorted((root/'MarginNotes.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
assert len(schemes) == 2
for path in schemes:
    tree = ET.parse(path)
    for ref in tree.findall('.//BuildableReference'): assert objects[ref.attrib['BlueprintIdentifier']]['isa'] == 'PBXNativeTarget'
    config = tree.find('LaunchAction').attrib['buildConfiguration']
    assert any(o['isa'] == 'XCBuildConfiguration' and o['name'] == config for o in objects.values())
tests = sum(len(re.findall(r'func test\w+\(', p.read_text())) for p in root.glob('Tests/**/*.swift'))
assert tests >= 15
for required in ['README.md','Docs/ICLOUD.md','Docs/INTERACTION.md','Docs/VALIDATION.md','Package.swift','Scripts/check.sh','Scripts/run-mac.sh']:
    assert (root/required).is_file(), required
print(f'PASS: OpenStep project parsed; {len(compiled)} Swift files included exactly once; 2 schemes resolved; 5 plists parsed; {tests} XCTest cases present.')
print('Swift tests, Apple SDK type checking and device behavior are not evaluated by this structural check.')
