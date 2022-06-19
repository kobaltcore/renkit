import system
import std/os
import std/json
import std/sets
import std/base64
import std/osproc
import std/tables
import std/streams
import std/strutils
import std/sequtils
import std/strformat
import std/algorithm

import nimpy
import nimpy/py_lib

import semver
import cligen
import parsetoml

import renutil
import renotize
import lib/common

type
  KeyboardInterrupt = object of CatchableError

  Task = object
    name: string
    instance: PyObject
    call: proc(input_dir: string, output_dir: string, config: JsonNode)
    builds: seq[string]
    priority: int

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

let find_libpython = "e=print\nT='.dylib'\nP='.so'\nK='lib'\nJ=len\nH=None\nfrom logging import getLogger as U\nfrom sysconfig import get_config_var as C\nfrom ctypes.util import find_library as Q\nimport ctypes as B,os as A,sys as D\nE=U('find_libpython')\nN=D.platform=='darwin'\nI=D.platform=='msys'\nL=D.platform=='mingw'\nG=A.name=='nt'and not L and not I\nR=A.name=='posix'\nF=C('_SHLIB_SUFFIX')\nif F is H:\n  if G:F='.dll'\n  else:F=P\nif N:F=T\ndef V(libpython):\n  D=libpython\n  if not hasattr(D,'Py_GetVersion'):return H\n  class E(B.Structure):_fields_=[('dli_fname',B.c_char_p),('dli_fbase',B.c_void_p),('dli_sname',B.c_char_p),('dli_saddr',B.c_void_p)]\n  C=B.CDLL(Q('dl'));C.dladdr.argtypes=[B.c_void_p,B.POINTER(E)];C.dladdr.restype=B.c_int;F=E();G=C.dladdr(B.cast(D.Py_GetVersion,B.c_void_p),B.pointer(F))\n  if G==0:return H\n  return A.path.realpath(F.dli_fname.decode())\ndef W(name,suffix=F,_is_windows=G):\n  B=suffix;A=name\n  if not _is_windows and A.startswith(K):A=A[J(K):]\n  if B and A.endswith(B):A=A[:-J(B)]\n  return A\ndef M(list,item):\n  if item:list.append(item)\ndef X(items):\n  B=set()\n  for A in items:\n    if A not in B:yield A\n    B.add(A)\ndef O(func):\n  from functools import wraps\n  @wraps(func)\n  def A(*A,**B):return X(func(*A,**B))\n  return A\n@O\ndef Y(suffix=F):\n  B=suffix;E=C('LDLIBRARY')\n  if E and A.path.splitext(E)[1]==B:yield E\n  F=C('LIBRARY')\n  if F and A.path.splitext(F)[1]==B:yield F\n  J=C('DLLLIBRARY')\n  if J:yield J\n  if L:H=K\n  elif G or I:H=''\n  else:H=K\n  M=dict(v=D.version_info,VERSION=C('VERSION')or '{v.major}.{v.minor}'.format(v=D.version_info),ABIFLAGS=C('ABIFLAGS')or C('abiflags')or'')\n  for N in ['python{VERSION}{ABIFLAGS}'.format(**M),'python{VERSION}'.format(**M)]:yield H+N+B\ndef Z():\n  C=B.cast(D.dllhandle,B.c_void_p);A=B.create_unicode_buffer(32768);E=B.windll.kernel32.GetModuleFileNameW(C,A,J(A))\n  if E==J(A):return H\n  return A.value\n@O\ndef a(suffix=F):\n  if G:yield Z()\n  E=[];M(E,C('LIBPL'));M(E,C('srcdir'));M(E,C('LIBDIR'))\n  if G or I or L:E.append(A.path.join(A.path.dirname(D.executable)))\n  else:E.append(A.path.join(A.path.dirname(A.path.dirname(D.executable)),K))\n  M(E,C('PYTHONFRAMEWORKPREFIX'));E.append(D.exec_prefix);E.append(A.path.join(D.exec_prefix,K));H=list(Y(suffix=suffix))\n  if R and not I:\n    for F in H:\n      try:J=B.CDLL(F)\n      except OSError:pass\n      else:yield V(J)\n  for N in E:\n    for F in H:yield A.path.join(N,F)\n  for F in H:yield Q(W(F))\ndef S(path,suffix=F,_is_apple=N):\n  C=suffix;B=path\n  if not B:return H\n  if not A.path.isabs(B):return H\n  if A.path.exists(B):return A.path.realpath(B)\n  if A.path.exists(B+C):return A.path.realpath(B+C)\n  if _is_apple:return S(b(B),suffix=P,_is_apple=False)\n  return H\ndef b(path):\n  A=path\n  if A.endswith(T):return A[:-J(T)]\n  if A.endswith(P):return A[:-J(P)]\n  return A\n@O\ndef c():\n  E.debug('_is_windows = %s',G);E.debug('_is_apple = %s',N);E.debug('_is_mingw = %s',L);E.debug('_is_msys = %s',I);E.debug('_is_posix = %s',R)\n  for B in a():\n    E.debug('Candidate: %s',B);A=S(B)\n    if A:E.debug('Found: %s',A);yield A\n    else:E.debug('Not found.')\ndef d():\n  for B in c():return A.path.realpath(B)\ndef f(items):\n  for A in items:e(A)\ne(d())"

var python_path = getEnv("RC_LIBPYTHON")

if python_path == "":
  let p = execCmdEx(&"python -c \"{find_libpython}\"")
  if p.exit_code != 0:
    echo "error while trying to find libpython"
    quit(1)
  python_path = p.output[0..^2]

let HAS_PYTHON = try:
  pyInitLibPath(python_path)
  let pysys = pyImport("sys")
  echo &"Python Support: true"
  echo &"Python Version: {pysys.version.to(string)}"
  true
except:
  echo &"Python Support: false"
  false

proc task_pre_convert_images(
  input_dir: string,
  output_dir: string,
  config: JsonNode,
) =
  for path, options in config{"tasks", "convert_images"}:
    if path == "enabled":
      continue

    let
      lossless = options{"lossless"}.getBool(true)
      recursive = options{"recursive"}.getBool(true)
      extensions = options{"extensions"}.getElems(@[%"png", %"jpg"]).mapIt(it.getStr())

    let files = input_dir.find_files(path, extensions, recursive)

    var attributes: seq[string]
    if recursive:
      attributes.add("recursive")
    if lossless:
      attributes.add("lossless")

    if attributes.len == 0:
      echo &"Processing {path} with {files.len} files"
    else:
      echo &"Processing {path} with {files.len} files ({attributes.join(\", \")})"

    var cmds: seq[string]
    if lossless:
      for file in files:
        cmds.add(&"cwebp -q 90 -m 6 -sharp_yuv -pre 4 {quoteShell(file)} -o {quoteShell(file)}")
    else:
      for file in files:
        cmds.add(&"cwebp -lossless -z 9 -m 6 {quoteShell(file)} -o {quoteShell(file)}")

    discard execProcesses(cmds, n = countProcessors(), options = {poUsePath})

proc task_post_clean(
  input_dir: string,
  output_dir: string,
  config: JsonNode,
) =
  let version = config{"renutil", "version"}.getStr().parseVersion()
  let registry = config{"renutil", "registry"}.getStr()
  cleanup($version, registry)
  if version < newVersion(7, 4, 9):
    for kind, path in walkDir(output_dir):
      if kind != pcFile:
        continue
      if path.endswith(".apk") and not path.endswith("-universal-release.apk"):
        removeFile(path)

proc task_post_notarize(
  input_dir: string,
  output_dir: string,
  config: JsonNode,
) =
  let files = walkFiles(joinPath(output_dir, "*-mac.zip")).to_seq
  if files.len != 1:
    echo "Could not find macOS ZIP file."
    quit(1)
  full_run(files[0], config{"tasks", "notarize"})

proc task_pre_keystore(
  input_dir: string,
  output_dir: string,
  config: JsonNode,
) =
  let
    version = config{"renutil", "version"}.getStr()
    registry = config{"renutil", "registry"}.getStr()
    keystore_path = joinPath(registry, version, "rapt", "android.keystore")
    keystore_path_backup = joinPath(registry, version, "rapt", "android.keystore.original")
    keystore_bundle_path = joinPath(registry, version, "rapt", "bundle.keystore")
    keystore_bundle_path_backup = joinPath(registry, version, "rapt", "bundle.keystore.original")

  var keystore = getEnv("RC_KEYSTORE_APK")

  if keystore == "":
    keystore = config{"tasks", "keystore", "keystore_apk"}.getStr()

  if keystore == "":
    echo("Keystore override was requested, but no APK keystore could be found.")
    quit(1)

  if not fileExists(keystore_path_backup):
    moveFile(keystore_path, keystore_path_backup)

  let stream_out_ks_apk = newFileStream(keystore_path, fmWrite)
  stream_out_ks_apk.write(decode(keystore))
  stream_out_ks_apk.close()

  keystore = getEnv("RC_KEYSTORE_AAB")

  if keystore == "":
    keystore = config{"tasks", "keystore", "keystore_aab"}.getStr()

  if keystore == "":
    echo("Keystore override was requested, but no AAB keystore could be found.")
    quit(1)

  if not fileExists(keystore_bundle_path_backup):
    moveFile(keystore_bundle_path, keystore_bundle_path_backup)

  let stream_out_ks_bundle = newFileStream(keystore_bundle_path, fmWrite)
  stream_out_ks_bundle.write(decode(keystore))
  stream_out_ks_bundle.close()

proc task_post_keystore(
  input_dir: string,
  output_dir: string,
  config: JsonNode,
) =
  let
    version = config{"renutil", "version"}.getStr()
    registry = config{"renutil", "registry"}.getStr()
    keystore_path = joinPath(registry, version, "rapt", "android.keystore")
    keystore_path_backup = joinPath(registry, version, "rapt", "android.keystore.original")
    keystore_bundle_path = joinPath(registry, version, "rapt", "bundle.keystore")
    keystore_bundle_path_backup = joinPath(registry, version, "rapt", "bundle.keystore.original")

  if fileExists(keystore_path_backup):
    moveFile(keystore_path_backup, keystore_path)

  if fileExists(keystore_bundle_path_backup):
    moveFile(keystore_bundle_path_backup, keystore_bundle_path)

proc validate*(config: JsonNode) =
  if "build" notin config:
    echo "Section 'build' not found, please add it."
    quit(1)

  if "pc" notin config["build"]:
    config{"build", "pc"} = %false
  if "win" notin config["build"]:
    config{"build", "win"} = %false
  if "linux" notin config["build"]:
    config{"build", "linux"} = %false
  if "mac" notin config["build"]:
    config{"build", "mac"} = %false
  if "web" notin config["build"]:
    config{"build", "web"} = %false
  if "steam" notin config["build"]:
    config{"build", "steam"} = %false
  if "market" notin config["build"]:
    config{"build", "market"} = %false
  if "android_apk" notin config["build"]:
    config{"build", "android_apk"} = %false
  if "android_aab" notin config["build"]:
    config{"build", "android_aab"} = %false

  var found_true = false
  for k, v in config["build"]:
    if v.getBool():
      found_true = true
      break

  if not found_true:
    echo "No option is enabled in the 'build' section."
    quit(1)

  if "renutil" notin config:
    echo "Section 'renutil' not found, please add it."
    quit(1)

  if "version" notin config["renutil"]:
    echo "Please specify the Ren'Py version in the 'renutil' section."
    quit(1)

  if config{"renutil", "version"}.getStr() == "latest":
    config{"renutil", "version"} = %list_available()[0]

  let renpy_version = config{"renutil", "version"}.getStr()
  echo &"Using Ren'Py version {renpy_version}"

  if config{"build", "web"}.getBool() and renpy_version < "7.3.0":
    echo "The 'web' build is not supported on versions below 7.3.0."
    quit(1)

  if "tasks" notin config:
    config{"tasks", "clean", "enabled"} = %false
    config{"tasks", "notarize", "enabled"} = %false
    config{"tasks", "keystore", "enabled"} = %false
    config{"tasks", "convert_images", "enabled"} = %false

  if "clean" notin config["tasks"]:
    config{"tasks", "clean", "enabled"} = %false

  if "notarize" notin config["tasks"]:
    config{"tasks", "notarize", "enabled"} = %false

  if "keystore" notin config["tasks"]:
    config{"tasks", "keystore", "enabled"} = %false

  if "convert_images" notin config["tasks"]:
    config{"tasks", "convert_images", "enabled"} = %false

  if "options" notin config:
    config{"options", "task_dir"} = %""
    config{"options", "clear_output_dir"} = %false

  if "task_dir" notin config["options"]:
    config{"options", "task_dir"} = %""

  if "clear_output_dir" notin config["options"]:
    config{"options", "clear_output_dir"} = %false

  let task_dir = config["options"]["task_dir"].getStr()
  if task_dir != "" and not dirExists(task_dir):
    echo &"Task directory '{task_dir}' does not exist."
    quit(1)

proc build*(
  input_dir: string,
  output_dir: string,
  config: string,
  registry = ""
) =
  ## Builds a Ren'Py project with the specified configuration.
  var
    task_count = 0
    registry_path: string
    tasks = initTable[string, seq[Task]]()

  tasks["pre"] = @[]
  tasks["post"] = @[]

  var config = parsetoml.parseFile(config).convert_to_json()

  config.validate()

  let active_builds = block:
    var builds: seq[string]
    for k, v in config["build"]:
      if v.getBool():
        builds.add(k)
    let result = toHashSet(builds)
    result

  if HAS_PYTHON:
    let task_dir = config{"options", "task_dir"}.getStr()
    if task_dir != "":
      let py = pyBuiltinsModule()
      let inspect = pyImport("inspect")
      discard pyImport("sys").path.append(task_dir)

      echo &"Scanning tasks in directory '{task_dir}'..."

      for file in walkDirRec(task_dir):
        if not file.endsWith(".py"):
          continue

        let (dir, name, ext) = splitFile(relativePath(file, task_dir))
        let import_path = joinPath(dir, name).replace($DirSep, ".")
        let module = pyImport(import_path.cstring)

        for info in inspect.getmembers(module, inspect.isclass):
          let
            name = info[0].to(string)
            class = info[1]

          if not name.endsWith("Task") or name == "Task":
            continue

          let config_name = name[0..^5].to_snake_case()
          var sub_config = config{"tasks", config_name}

          if py.hasattr(class, "validate_config").to(bool):
            try:
              if sub_config == nil:
                config{"tasks", config_name} = class.validate_config(%*{}).to(JsonNode)
              else:
                config{"tasks", config_name} = class.validate_config(sub_config).to(JsonNode)
            except:
              echo &"Failed to validate config for task {name}: {getCurrentExceptionMsg()}"
              quit(1)

          sub_config = config{"tasks", config_name}

          if not sub_config{"enabled"}.getBool():
            continue

          task_count += 1

          # create new instance
          let instance = class.callMethod("__new__", class, config)
          # init instance
          discard class.callMethod("__init__", instance, config, input_dir, output_dir)

          let builds = block:
            var results = block:
              var builds: seq[string]
              for k, v in config["build"]:
                builds.add(k)
              builds
            let result = sub_config{"on_builds"}.getElems().mapIt(it.getStr())
            if result.len > 0:
              results = result
            results

          if py.hasattr(instance, "pre_build").to(bool):
            tasks["pre"].add(
              Task(
                name: config_name,
                instance: instance,
                builds: builds,
                priority: sub_config{"priorities", "pre_build"}.getInt(0),
              )
            )

          if py.hasattr(instance, "post_build").to(bool):
            tasks["post"].add(
              Task(
                name: config_name,
                instance: instance,
                builds: builds,
                priority: sub_config{"priorities", "post_build"}.getInt(0),
              )
            )

          echo &"Loaded Task: {name}"
  else:
    echo "Python Support: false"

  if config{"tasks", "clean", "enabled"}.getBool():
    tasks["post"].add(
      Task(
        name: "clean",
        call: task_post_clean,
        builds: block:
          var results = block:
            var builds: seq[string]
            for k, v in config["build"]:
              builds.add(k)
            builds
          let result = config{"tasks", "clean", "on_builds"}.getElems().mapIt(it.getStr())
          if result.len > 0:
            results = result
          results,
        priority: config{"tasks", "clean", "priorities", "post_build"}.getInt(0),
      )
    )
    task_count += 1
    echo &"Loaded Task: clean"

  if config{"tasks", "notarize", "enabled"}.getBool():
    tasks["post"].add(
      Task(
        name: "notarize",
        call: task_post_notarize,
        builds: block:
          var results = @["mac"]
          let result = config{"tasks", "notarize", "on_builds"}.getElems().mapIt(it.getStr())
          if result.len > 0:
            results = result
          results,
        priority: config{"tasks", "notarize", "priorities", "post_build"}.getInt(10),
      )
    )
    task_count += 1
    echo &"Loaded Task: notarize"

  if config{"tasks", "convert_images", "enabled"}.getBool():
    tasks["pre"].add(
      Task(
        name: "convert_images",
        call: task_pre_convert_images,
        builds: block:
          var results = block:
            var builds: seq[string]
            for k, v in config["build"]:
              builds.add(k)
            builds
          let result = config{"tasks", "convert_images", "on_builds"}.getElems().mapIt(it.getStr())
          if result.len > 0:
            results = result
          results,
        priority: config{"tasks", "convert_images", "priorities", "post_build"}.getInt(10),
      )
    )
    task_count += 1
    echo &"Loaded Task: convert_images"

  if config{"tasks", "keystore", "enabled"}.getBool():
    tasks["pre"].add(
      Task(
        name: "keystore",
        call: task_pre_keystore,
        builds: block:
          var results = @["android_apk", "android_aab"]
          let result = config{"tasks", "keystore", "on_builds"}.getElems().mapIt(it.getStr())
          if result.len > 0:
            results = result
          results,
        priority: config{"tasks", "keystore", "priorities", "pre_build"}.getInt(0),
      )
    )
    tasks["post"].add(
      Task(
        name: "keystore",
        call: task_pre_keystore,
        builds: block:
          var results = @["android_apk", "android_aab"]
          let result = config{"tasks", "keystore", "on_builds"}.getElems().mapIt(it.getStr())
          if result.len > 0:
            results = result
          results,
        priority: config{"tasks", "keystore", "priorities", "post_build"}.getInt(0),
      )
    )
    task_count += 1
    echo &"Loaded Task: keystore"

  tasks["pre"] = tasks["pre"].sortedByIt((it.priority, it.name)).reversed()
  tasks["post"] = tasks["post"].sortedByIt((it.priority, it.name)).reversed()

  if task_count == 1:
    echo "Loaded 1 task"
  else:
    echo &"Loaded {task_count} tasks"

  if registry != "":
    registry_path = get_registry(registry)
  elif "registry" in config["renutil"]:
    registry_path = get_registry(config["renutil"]["registry"].getStr())
  else:
    registry_path = get_registry(registry)

  if not dirExists(input_dir):
    echo(&"Game directory '{input_dir}' does not exist.")
    quit(1)

  if config["options"]["clear_output_dir"].getBool() and dirExists(output_dir):
    removeDir(output_dir)

  createDir(output_dir)

  let renutil_target_version = parseVersion(config["renutil"]["version"].getStr())

  if not is_installed(renutil_target_version, registry_path):
    echo(&"Installing Ren'Py {renutil_target_version}")
    install($renutil_target_version, registry_path)

  for task in tasks["pre"]:
    if (active_builds * task.builds.to_hash_set).len == 0:
      continue
    echo &"Running pre-build task {task.name} with priority {task.priority}"
    if task.call != nil:
      task.call(input_dir, output_dir, config)
    else:
      discard task.instance.pre_build()

  if config["build"]["android_apk"].getBool() or
    config{"build", "android"}.getBool(): # for backwards-compatibility with older config files
    echo("Building Android APK package.")
    if renutil_target_version >= newVersion(7, 4, 9):
      launch(
        $renutil_target_version,
        false,
        false,
        &"android_build {quoteShell(input_dir)} --dest {quoteShell(absolutePath(output_dir))}",
        registry_path
      )
    else:
      launch(
        $renutil_target_version,
        false,
        false,
        &"android_build {quoteShell(input_dir)} assembleRelease --dest {quoteShell(absolutePath(output_dir))}",
        registry_path
      )

  if config["build"]["android_aab"].getBool():
    echo("Building Android AAB package.")
    if renutil_target_version >= newVersion(7, 4, 9):
      launch(
        $renutil_target_version,
        false,
        false,
        &"android_build {quoteShell(input_dir)} --bundle --dest {quoteShell(absolutePath(output_dir))}",
        registry_path
      )
    else:
      echo "Not supported for Ren'Py versions <7.4.9"
      quit(1)

  var platforms_to_build: seq[string]
  if "pc" in config["build"] and config["build"]["pc"].getBool():
    platforms_to_build.add("pc")
  if "mac" in config["build"] and config["build"]["mac"].getBool():
    platforms_to_build.add("mac")
  if "win" in config["build"] and config["build"]["win"].getBool():
    platforms_to_build.add("win")
  if "linux" in config["build"] and config["build"]["linux"].getBool():
    platforms_to_build.add("linux")
  if "market" in config["build"] and config["build"]["market"].getBool():
    platforms_to_build.add("market")
  if "steam" in config["build"] and config["build"]["steam"].getBool():
    platforms_to_build.add("steam")
  if "web" in config["build"] and config["build"]["web"].getBool():
    # make out_dir = {project-name}-{version}-web directory in output directory
    # modify build command:
    # --destination {out_dir} --packagedest joinPath(out_dir, "game") --package web --no-archive
    # TODO: somehow trigger repack_for_progressive_download()
    # copy files from {version}/web except for hash.txt to the web output directory
    # modify index.html and replace %%TITLE%% with the game's display name
    platforms_to_build.add("web")

  if len(platforms_to_build) > 0:
    var cmd = &"distribute {quoteShell(input_dir)} --destination {quoteShell(absolutePath(output_dir))}"
    for package in platforms_to_build:
      cmd = cmd & &" --package {package}"
    let joined_packages = join(platforms_to_build, ", ")

    echo(&"Building {joined_packages} packages.")
    launch(
      $renutil_target_version,
      false,
      false,
      cmd,
      registry_path
    )

  for task in tasks["post"]:
    if (active_builds * task.builds.to_hash_set).len == 0:
      continue
    echo &"Running post-build task {task.name} with priority {task.priority}"
    if task.call != nil:
      task.call(input_dir, output_dir, config)
    else:
      discard task.instance.post_build()

when isMainModule:
  try:
    dispatchMulti(
      [build, help = {
          "input_dir": "The path to the Ren'Py project to build.",
          "output_dir": "The directory to output distributions to.",
          "config": "The path to the configuration file to use.",
          "registry": "The path to the registry directory to use. Defaults to ~/.renutil",
      }],
    )
  except KeyboardInterrupt:
    echo "\nAborted by SIGINT"
    quit(1)
