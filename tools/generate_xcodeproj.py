# Erzeugt SyllaBeat.xcodeproj (synchronisierte Ordner, lokales Paket, Schema). Aufruf: python3 tools/generate_xcodeproj.py .
import os, sys
root = sys.argv[1]
n = [0]
def oid(tag):
    n[0] += 1
    return "5B%022X" % (n[0] * 7919 + hash(tag) % 7)  # stable-enough unique
ids = {}
def I(name):
    if name not in ids:
        n[0] += 1
        ids[name] = "5BEA7%019X" % n[0]
    return ids[name]

proj = I("project")
main = I("mainGroup"); products = I("productsGroup"); config = I("configGroup")
g_app, g_inf, g_ui = I("g.App"), I("g.Inference"), I("g.UITests")
pkg = I("pkg")
t_app, t_inf, t_ui = I("t.app"), I("t.inf"), I("t.ui")
p_app, p_inf, p_ui = I("p.app"), I("p.inf"), I("p.ui")
f_base, f_dbg, f_rel, f_ver, f_aplist, f_iplist = I("f.base"), I("f.dbg"), I("f.rel"), I("f.ver"), I("f.aplist"), I("f.iplist")
dep_app_core, dep_app_ai, dep_inf_core, dep_inf_ai = I("d.app.core"), I("d.app.ai"), I("d.inf.core"), I("d.inf.ai")
bf_app_core, bf_app_ai, bf_inf_core, bf_inf_ai = I("bf.app.core"), I("bf.app.ai"), I("bf.inf.core"), I("bf.inf.ai")
bf_embed = I("bf.embed")
dep_app_media, bf_app_media = I("d.app.media"), I("bf.app.media")
dep_inf_models, bf_inf_models = I("d.inf.models"), I("bf.inf.models")
dep_app_audio, bf_app_audio = I("d.app.audio"), I("bf.app.audio")
dep_app_ui, bf_app_ui = I("d.app.ui"), I("bf.app.ui")
ph = {k: I("ph."+k) for k in ["app.src","app.fw","app.res","app.embed","inf.src","inf.fw","inf.res","ui.src","ui.fw","ui.res"]}
proxy_inf, proxy_app = I("proxy.inf"), I("proxy.app")
td_inf, td_app = I("td.inf"), I("td.app")
cl = {k: I("cl."+k) for k in ["proj","app","inf","ui"]}
bc = {k: I("bc."+k) for k in ["proj.d","proj.r","app.d","app.r","inf.d","inf.r","ui.d","ui.r"]}

def settings(d, indent="\t\t\t\t"):
    out = []
    for k, v in d.items():
        if isinstance(v, list):
            out.append(f"{indent}{k} = (\n" + "".join(f"{indent}\t\"{x}\",\n" for x in v) + f"{indent});")
        else:
            val = v if (v.replace("_","").replace(".","").isalnum() and v) else f"\"{v}\""
            out.append(f"{indent}{k} = {val};")
    return "\n".join(out)

app_settings = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "COMBINE_HIDPI_IMAGES": "YES",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": "Config/App-Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "SyllaBeat",
    "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.video",
    "INFOPLIST_KEY_NSHumanReadableCopyright": "© 2026 Buffer379x",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    "PRODUCT_BUNDLE_IDENTIFIER": "de.syllabeat.app",
    "PRODUCT_NAME": "SyllaBeat",
}
inf_settings = {
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": "Config/Inference-Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "SyllaBeatInference",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../../../../Frameworks"],
    "PRODUCT_BUNDLE_IDENTIFIER": "de.syllabeat.app.inference",
    "PRODUCT_NAME": "SyllaBeatInference",
    "SKIP_INSTALL": "YES",
}
ui_settings = {
    "GENERATE_INFOPLIST_FILE": "YES",
    "PRODUCT_BUNDLE_IDENTIFIER": "de.syllabeat.app.uitests",
    "PRODUCT_NAME": "SyllaBeatUITests",
    "TEST_TARGET_NAME": "SyllaBeat",
}

def bconf(cid, name, base, s):
    return f"""\t\t{cid} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
{"" if base is None else f"			baseConfigurationReference = {base};" + chr(10)}\t\t\tbuildSettings = {{
{settings(s)}
\t\t\t}};
\t\t\tname = {name};
\t\t}};
"""

txt = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 77;
\tobjects = {{

/* Begin PBXBuildFile section */
\t\t{bf_app_core} /* SyllaBeatCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_app_core} /* SyllaBeatCore */; }};
\t\t{bf_app_ai} /* SyllaBeatAI in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_app_ai} /* SyllaBeatAI */; }};
\t\t{bf_inf_core} /* SyllaBeatCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_inf_core} /* SyllaBeatCore */; }};
\t\t{bf_inf_ai} /* SyllaBeatAI in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_inf_ai} /* SyllaBeatAI */; }};
\t\t{bf_app_media} /* SyllaBeatMedia in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_app_media} /* SyllaBeatMedia */; }};
\t\t{bf_inf_models} /* SyllaBeatModels in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_inf_models} /* SyllaBeatModels */; }};
\t\t{bf_app_audio} /* SyllaBeatAudio in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_app_audio} /* SyllaBeatAudio */; }};
\t\t{bf_app_ui} /* SyllaBeatUI in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_app_ui} /* SyllaBeatUI */; }};
\t\t{bf_embed} /* SyllaBeatInference.xpc in Embed XPC Services */ = {{isa = PBXBuildFile; fileRef = {p_inf} /* SyllaBeatInference.xpc */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
\t\t{proxy_inf} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {proj} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {t_inf};
\t\t\tremoteInfo = SyllaBeatInference;
\t\t}};
\t\t{proxy_app} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {proj} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {t_app};
\t\t\tremoteInfo = SyllaBeat;
\t\t}};
/* End PBXContainerItemProxy section */

/* Begin PBXCopyFilesBuildPhase section */
\t\t{ph['app.embed']} /* Embed XPC Services */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "$(CONTENTS_FOLDER_PATH)/XPCServices";
\t\t\tdstSubfolderSpec = 16;
\t\t\tfiles = (
\t\t\t\t{bf_embed} /* SyllaBeatInference.xpc in Embed XPC Services */,
\t\t\t);
\t\t\tname = "Embed XPC Services";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFileReference section */
\t\t{p_app} /* SyllaBeat.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SyllaBeat.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{p_inf} /* SyllaBeatInference.xpc */ = {{isa = PBXFileReference; explicitFileType = "wrapper.xpc-service"; includeInIndex = 0; path = SyllaBeatInference.xpc; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{p_ui} /* SyllaBeatUITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = SyllaBeatUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{f_base} /* Base.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Base.xcconfig; sourceTree = "<group>"; }};
\t\t{f_dbg} /* Debug.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Debug.xcconfig; sourceTree = "<group>"; }};
\t\t{f_rel} /* Release.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Release.xcconfig; sourceTree = "<group>"; }};
\t\t{f_ver} /* Version.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Version.xcconfig; sourceTree = "<group>"; }};
\t\t{f_aplist} /* App-Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "App-Info.plist"; sourceTree = "<group>"; }};
\t\t{f_iplist} /* Inference-Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Inference-Info.plist"; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
\t\t{g_app} /* App */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; }};
\t\t{g_inf} /* InferenceService */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = InferenceService; sourceTree = "<group>"; }};
\t\t{g_ui} /* UITests */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = UITests; sourceTree = "<group>"; }};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{ph['app.fw']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{bf_app_core} /* SyllaBeatCore in Frameworks */,
\t\t\t\t{bf_app_ai} /* SyllaBeatAI in Frameworks */,
\t\t\t\t{bf_app_media} /* SyllaBeatMedia in Frameworks */,
\t\t\t\t{bf_app_audio} /* SyllaBeatAudio in Frameworks */,
\t\t\t\t{bf_app_ui} /* SyllaBeatUI in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{ph['inf.fw']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{bf_inf_core} /* SyllaBeatCore in Frameworks */,
\t\t\t\t{bf_inf_ai} /* SyllaBeatAI in Frameworks */,
\t\t\t\t{bf_inf_models} /* SyllaBeatModels in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{ph['ui.fw']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{main} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{g_app} /* App */,
\t\t\t\t{g_inf} /* InferenceService */,
\t\t\t\t{g_ui} /* UITests */,
\t\t\t\t{config} /* Config */,
\t\t\t\t{products} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{config} /* Config */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{f_ver} /* Version.xcconfig */,
\t\t\t\t{f_base} /* Base.xcconfig */,
\t\t\t\t{f_dbg} /* Debug.xcconfig */,
\t\t\t\t{f_rel} /* Release.xcconfig */,
\t\t\t\t{f_aplist} /* App-Info.plist */,
\t\t\t\t{f_iplist} /* Inference-Info.plist */,
\t\t\t);
\t\t\tpath = Config;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{products} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{p_app} /* SyllaBeat.app */,
\t\t\t\t{p_inf} /* SyllaBeatInference.xpc */,
\t\t\t\t{p_ui} /* SyllaBeatUITests.xctest */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{t_app} /* SyllaBeat */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cl['app']} /* Build configuration list for PBXNativeTarget "SyllaBeat" */;
\t\t\tbuildPhases = (
\t\t\t\t{ph['app.src']} /* Sources */,
\t\t\t\t{ph['app.fw']} /* Frameworks */,
\t\t\t\t{ph['app.res']} /* Resources */,
\t\t\t\t{ph['app.embed']} /* Embed XPC Services */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{td_inf} /* PBXTargetDependency */,
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{g_app} /* App */,
\t\t\t);
\t\t\tname = SyllaBeat;
\t\t\tpackageProductDependencies = (
\t\t\t\t{dep_app_core} /* SyllaBeatCore */,
\t\t\t\t{dep_app_ai} /* SyllaBeatAI */,
\t\t\t\t{dep_app_media} /* SyllaBeatMedia */,
\t\t\t\t{dep_app_audio} /* SyllaBeatAudio */,
\t\t\t\t{dep_app_ui} /* SyllaBeatUI */,
\t\t\t);
\t\t\tproductName = SyllaBeat;
\t\t\tproductReference = {p_app} /* SyllaBeat.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
\t\t{t_inf} /* SyllaBeatInference */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cl['inf']} /* Build configuration list for PBXNativeTarget "SyllaBeatInference" */;
\t\t\tbuildPhases = (
\t\t\t\t{ph['inf.src']} /* Sources */,
\t\t\t\t{ph['inf.fw']} /* Frameworks */,
\t\t\t\t{ph['inf.res']} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{g_inf} /* InferenceService */,
\t\t\t);
\t\t\tname = SyllaBeatInference;
\t\t\tpackageProductDependencies = (
\t\t\t\t{dep_inf_core} /* SyllaBeatCore */,
\t\t\t\t{dep_inf_ai} /* SyllaBeatAI */,
\t\t\t\t{dep_inf_models} /* SyllaBeatModels */,
\t\t\t);
\t\t\tproductName = SyllaBeatInference;
\t\t\tproductReference = {p_inf} /* SyllaBeatInference.xpc */;
\t\t\tproductType = "com.apple.product-type.xpc-service";
\t\t}};
\t\t{t_ui} /* SyllaBeatUITests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cl['ui']} /* Build configuration list for PBXNativeTarget "SyllaBeatUITests" */;
\t\t\tbuildPhases = (
\t\t\t\t{ph['ui.src']} /* Sources */,
\t\t\t\t{ph['ui.fw']} /* Frameworks */,
\t\t\t\t{ph['ui.res']} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{td_app} /* PBXTargetDependency */,
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{g_ui} /* UITests */,
\t\t\t);
\t\t\tname = SyllaBeatUITests;
\t\t\tproductName = SyllaBeatUITests;
\t\t\tproductReference = {p_ui} /* SyllaBeatUITests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.ui-testing";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{proj} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2710;
\t\t\t\tLastUpgradeCheck = 2710;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{t_app} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 27.1;
\t\t\t\t\t}};
\t\t\t\t\t{t_inf} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 27.1;
\t\t\t\t\t}};
\t\t\t\t\t{t_ui} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 27.1;
\t\t\t\t\t\tTestTargetID = {t_app};
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {cl['proj']} /* Build configuration list for PBXProject "SyllaBeat" */;
\t\t\tdevelopmentRegion = de;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\tde,
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {main};
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpackageReferences = (
\t\t\t\t{pkg} /* XCLocalSwiftPackageReference "Packages/SyllaBeatKit" */,
\t\t\t);
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {products} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{t_app} /* SyllaBeat */,
\t\t\t\t{t_inf} /* SyllaBeatInference */,
\t\t\t\t{t_ui} /* SyllaBeatUITests */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
""" + "".join(f"""\t\t{ph[k]} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
""" for k in ["app.res","inf.res","ui.res"]) + """/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
""" + "".join(f"""\t\t{ph[k]} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
""" for k in ["app.src","inf.src","ui.src"]) + f"""/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
\t\t{td_inf} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {t_inf} /* SyllaBeatInference */;
\t\t\ttargetProxy = {proxy_inf} /* PBXContainerItemProxy */;
\t\t}};
\t\t{td_app} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {t_app} /* SyllaBeat */;
\t\t\ttargetProxy = {proxy_app} /* PBXContainerItemProxy */;
\t\t}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
""" + bconf(bc['proj.d'], "Debug", f_dbg, {}) + bconf(bc['proj.r'], "Release", f_rel, {}) \
    + bconf(bc['app.d'], "Debug", None, app_settings) + bconf(bc['app.r'], "Release", None, app_settings) \
    + bconf(bc['inf.d'], "Debug", None, inf_settings) + bconf(bc['inf.r'], "Release", None, inf_settings) \
    + bconf(bc['ui.d'], "Debug", None, ui_settings) + bconf(bc['ui.r'], "Release", None, ui_settings) + """/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
""" + "".join(f"""\t\t{cl[k]} /* Build configuration list for {kind} "{name}" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{bc[k2+'.d']} /* Debug */,
\t\t\t\t{bc[k2+'.r']} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
""" for k, k2, kind, name in [("proj","proj","PBXProject","SyllaBeat"),("app","app","PBXNativeTarget","SyllaBeat"),("inf","inf","PBXNativeTarget","SyllaBeatInference"),("ui","ui","PBXNativeTarget","SyllaBeatUITests")]) + f"""/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
\t\t{pkg} /* XCLocalSwiftPackageReference "Packages/SyllaBeatKit" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = Packages/SyllaBeatKit;
\t\t}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
""" + "".join(f"""\t\t{d} /* {prod} */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {pkg} /* XCLocalSwiftPackageReference "Packages/SyllaBeatKit" */;
\t\t\tproductName = {prod};
\t\t}};
""" for d, prod in [(dep_app_core,"SyllaBeatCore"),(dep_app_ai,"SyllaBeatAI"),(dep_inf_core,"SyllaBeatCore"),(dep_inf_ai,"SyllaBeatAI"),(dep_app_media,"SyllaBeatMedia"),(dep_inf_models,"SyllaBeatModels"),(dep_app_audio,"SyllaBeatAudio"),(dep_app_ui,"SyllaBeatUI")]) + f"""/* End XCSwiftPackageProductDependency section */
\t}};
\trootObject = {proj} /* Project object */;
}}
"""
os.makedirs(f"{root}/SyllaBeat.xcodeproj/xcshareddata/xcschemes", exist_ok=True)
open(f"{root}/SyllaBeat.xcodeproj/project.pbxproj", "w").write(txt)

def ref(t, name, product):
    return f"""<BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{t}"
               BuildableName = "{product}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:SyllaBeat.xcodeproj">
            </BuildableReference>"""
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2710"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {ref(t_app, "SyllaBeat", "SyllaBeat.app")}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            {ref(t_ui, "SyllaBeatUITests", "SyllaBeatUITests.xctest")}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref(t_app, "SyllaBeat", "SyllaBeat.app")}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref(t_app, "SyllaBeat", "SyllaBeat.app")}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
open(f"{root}/SyllaBeat.xcodeproj/xcshareddata/xcschemes/SyllaBeat.xcscheme", "w").write(scheme)
print("ok")
