#!/usr/bin/env python3
"""Generate a dependency-free, multiplatform Xcode project with stable object IDs."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'MarginNotes.xcodeproj'
PROJECT.mkdir(exist_ok=True)
objects = {}
def uid(label): return hashlib.sha256(label.encode()).hexdigest()[:24].upper()
def obj(label, value):
    key = uid(label); objects[key] = value; return key
def array(*values): return list(values)

sources = sorted(ROOT.glob('Sources/**/*.swift'))
source_refs, build_refs = [], []
for path in sources:
    rel = str(path.relative_to(ROOT))
    ref = obj('file:' + rel, {'isa':'PBXFileReference','lastKnownFileType':'sourcecode.swift','path':rel,'sourceTree':'<group>'})
    source_refs.append(ref)
    build_refs.append(obj('build:' + rel, {'isa':'PBXBuildFile','fileRef':ref}))
config_refs = {}
for name in ['Base.xcconfig', 'Cloud.xcconfig', 'Info.plist', 'Mac.entitlements', 'iPad.entitlements', 'Mac-Cloud.entitlements', 'iPad-Cloud.entitlements']:
    config_refs[name] = obj('configfile:' + name, {'isa':'PBXFileReference','lastKnownFileType':'text.xcconfig' if name.endswith('xcconfig') else 'text.plist.xml','path':'Config/' + name,'sourceTree':'<group>'})
product = obj('product', {'isa':'PBXFileReference','explicitFileType':'wrapper.application','includeInIndex':'0','path':'Libere.app','sourceTree':'BUILT_PRODUCTS_DIR'})
products = obj('products', {'isa':'PBXGroup','children':[product],'name':'Products','sourceTree':'<group>'})
source_group = obj('sources', {'isa':'PBXGroup','children':source_refs,'name':'Sources','sourceTree':'<group>'})
config_group = obj('config', {'isa':'PBXGroup','children':list(config_refs.values()),'name':'Config','sourceTree':'<group>'})
root_group = obj('root', {'isa':'PBXGroup','children':[source_group, config_group, products],'sourceTree':'<group>'})
source_phase = obj('sourcephase', {'isa':'PBXSourcesBuildPhase','buildActionMask':'2147483647','files':build_refs,'runOnlyForDeploymentPostprocessing':'0'})
framework_phase = obj('frameworkphase', {'isa':'PBXFrameworksBuildPhase','buildActionMask':'2147483647','files':[],'runOnlyForDeploymentPostprocessing':'0'})
resource_builds = []
for path in sorted((ROOT/'Sources/MarginNotes/Resources').glob('*')):
    if path.name.startswith('.') or not (path.is_file() or path.suffix == '.xcassets'): continue
    rel = str(path.relative_to(ROOT))
    kind = {'.xcassets':'folder.assetcatalog', '.png':'image.png', '.py':'text.script.python'}.get(path.suffix, 'file')
    ref = obj('resource:' + rel, {'isa':'PBXFileReference','lastKnownFileType':kind,'path':rel,'sourceTree':'<group>'})
    source_refs.append(ref)
    resource_builds.append(obj('resourcebuild:' + rel, {'isa':'PBXBuildFile','fileRef':ref}))
resource_phase = obj('resourcephase', {'isa':'PBXResourcesBuildPhase','buildActionMask':'2147483647','files':resource_builds,'runOnlyForDeploymentPostprocessing':'0'})
project_configs, target_configs = [], []
for name in ['Debug','Release','iCloud']:
    debug = name != 'Release'
    project_configs.append(obj('projectconfig:' + name, {'isa':'XCBuildConfiguration','name':name,'buildSettings':{'CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','ENABLE_USER_SCRIPT_SANDBOXING':'YES','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if debug else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if debug else 'dwarf-with-dsym'}}))
    target_configs.append(obj('targetconfig:' + name, {'isa':'XCBuildConfiguration','name':name,'baseConfigurationReference':config_refs['Cloud.xcconfig' if name == 'iCloud' else 'Base.xcconfig'],'buildSettings':{'PRODUCT_NAME':'Libere','SWIFT_EMIT_LOC_STRINGS':'YES','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@executable_path/../Frameworks'],'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG $(inherited)' if debug else '$(inherited)'}}))
pconfigs = obj('pconfigs', {'isa':'XCConfigurationList','buildConfigurations':project_configs,'defaultConfigurationIsVisible':'0','defaultConfigurationName':'Release'})
tconfigs = obj('tconfigs', {'isa':'XCConfigurationList','buildConfigurations':target_configs,'defaultConfigurationIsVisible':'0','defaultConfigurationName':'Release'})
target = obj('target', {'isa':'PBXNativeTarget','buildConfigurationList':tconfigs,'buildPhases':[source_phase,framework_phase,resource_phase],'buildRules':[],'dependencies':[],'name':'MarginNotes','productName':'Libere','productReference':product,'productType':'com.apple.product-type.application'})
project = obj('project', {'isa':'PBXProject','attributes':{'LastUpgradeCheck':'1600','BuildIndependentTargetsInParallel':'YES','TargetAttributes':{target:{'CreatedOnToolsVersion':'16.0','SystemCapabilities':{'com.apple.iCloud':{'enabled':'1'}}}}},'buildConfigurationList':pconfigs,'compatibilityVersion':'Xcode 14.0','developmentRegion':'zh-Hans','hasScannedForEncodings':'0','knownRegions':['zh-Hans','en','Base'],'mainGroup':root_group,'productRefGroup':products,'projectDirPath':'','projectRoot':'','targets':[target]})
def encode(value, depth=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('\t'*(depth+1)+json.dumps(k,ensure_ascii=False)+' = '+encode(v,depth+1)+';\n' for k,v in value.items()) + '\t'*depth+'}'
    if isinstance(value, list): return '(' + ', '.join(encode(v,depth) for v in value) + (',' if value else '') + ')'
    return json.dumps(str(value),ensure_ascii=False)
document = {'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project}
(PROJECT/'project.pbxproj').write_text('// !$*UTF8*$!\n'+encode(document)+'\n')

schemes = PROJECT/'xcshareddata'/'xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
for name, config in [('MarginNotes','Debug'),('MarginNotes-iCloud','iCloud')]:
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Libere.app" BlueprintName="MarginNotes" ReferencedContainer="container:MarginNotes.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="{config}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
 <LaunchAction buildConfiguration="{config}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="{config}"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    (schemes/(name+'.xcscheme')).write_text(scheme)

info = {
 'CFBundleDevelopmentRegion':'zh-Hans','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)',
 'CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'Libere','CFBundleDisplayName':'Libere','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)',
 'LSApplicationCategoryType':'public.app-category.productivity','LSMinimumSystemVersion':'$(MACOSX_DEPLOYMENT_TARGET)',
 'NSHighResolutionCapable':True,'UIApplicationSupportsIndirectInputEvents':True,
 'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False},'UILaunchScreen':{},
 'UISupportedInterfaceOrientations~ipad':['UIInterfaceOrientationPortrait','UIInterfaceOrientationPortraitUpsideDown','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],
 'UIBackgroundModes':['remote-notification'],
 'MarginCloudEnabled':'$(MARGIN_CLOUD_ENABLED)','MarginCloudContainer':'$(MARGIN_CLOUD_CONTAINER)',
 'UTExportedTypeDeclarations':[
  {'UTTypeIdentifier':'app.marginnotes.backup','UTTypeDescription':'Libere 完整备份','UTTypeConformsTo':['public.json'], 'UTTypeTagSpecification':{'public.filename-extension':['marginbackup'],'public.mime-type':'application/json'}},
  {'UTTypeIdentifier':'app.marginnotes.page-drag','UTTypeDescription':'Libere 页面移动','UTTypeConformsTo':['public.data']}
 ]
}
def plist(name, value): (ROOT/'Config'/name).write_bytes(plistlib.dumps(value,sort_keys=False))
plist('Info.plist',info)
mac = {'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-write':True,'com.apple.security.network.client':True,'com.apple.security.network.server':True,'com.apple.security.files.bookmarks.app-scope':True}
plist('Mac.entitlements',mac); plist('iPad.entitlements',{})
cloud = {'com.apple.developer.icloud-container-identifiers':['$(MARGIN_CLOUD_CONTAINER)'],'com.apple.developer.icloud-services':['CloudKit']}
plist('Mac-Cloud.entitlements',dict(mac,**cloud,**{'com.apple.developer.aps-environment':'development'}))
plist('iPad-Cloud.entitlements',dict(cloud,**{'aps-environment':'development'}))
print(f'Generated Xcode project with {len(sources)} Swift sources and 2 shared schemes.')
