import std/os
import std/json
import std/sets
import std/osproc
import std/tables
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
import lib/common
import lib/rc_tasks

type
  KeyboardInterrupt = object of CatchableError

  Task = object
    name: string
    instance: PyObject
    call: proc(config: JsonNode, inputDir: string, outputDir: string)
    builds: seq[string]
    priority: int

proc handler() {.noconv.} =
  raise newException(KeyboardInterrupt, "Keyboard Interrupt")

setControlCHook(handler)

let findLibpython = "e=print\nT='.dylib'\nP='.so'\nK='lib'\nJ=len\nH=None\nfrom logging import getLogger as U\nfrom sysconfig import get_config_var as C\nfrom ctypes.util import find_library as Q\nimport ctypes as B,os as A,sys as D\nE=U('find_libpython')\nN=D.platform=='darwin'\nI=D.platform=='msys'\nL=D.platform=='mingw'\nG=A.name=='nt'and not L and not I\nR=A.name=='posix'\nF=C('_SHLIB_SUFFIX')\nif F is H:\n  if G:F='.dll'\n  else:F=P\nif N:F=T\ndef V(libpython):\n  D=libpython\n  if not hasattr(D,'Py_GetVersion'):return H\n  class E(B.Structure):_fields_=[('dli_fname',B.c_char_p),('dli_fbase',B.c_void_p),('dli_sname',B.c_char_p),('dli_saddr',B.c_void_p)]\n  C=B.CDLL(Q('dl'));C.dladdr.argtypes=[B.c_void_p,B.POINTER(E)];C.dladdr.restype=B.c_int;F=E();G=C.dladdr(B.cast(D.Py_GetVersion,B.c_void_p),B.pointer(F))\n  if G==0:return H\n  return A.path.realpath(F.dli_fname.decode())\ndef W(name,suffix=F,_is_windows=G):\n  B=suffix;A=name\n  if not _is_windows and A.startswith(K):A=A[J(K):]\n  if B and A.endswith(B):A=A[:-J(B)]\n  return A\ndef M(list,item):\n  if item:list.append(item)\ndef X(items):\n  B=set()\n  for A in items:\n    if A not in B:yield A\n    B.add(A)\ndef O(func):\n  from functools import wraps\n  @wraps(func)\n  def A(*A,**B):return X(func(*A,**B))\n  return A\n@O\ndef Y(suffix=F):\n  B=suffix;E=C('LDLIBRARY')\n  if E and A.path.splitext(E)[1]==B:yield E\n  F=C('LIBRARY')\n  if F and A.path.splitext(F)[1]==B:yield F\n  J=C('DLLLIBRARY')\n  if J:yield J\n  if L:H=K\n  elif G or I:H=''\n  else:H=K\n  M=dict(v=D.version_info,VERSION=C('VERSION')or '{v.major}.{v.minor}'.format(v=D.version_info),ABIFLAGS=C('ABIFLAGS')or C('abiflags')or'')\n  for N in ['python{VERSION}{ABIFLAGS}'.format(**M),'python{VERSION}'.format(**M)]:yield H+N+B\ndef Z():\n  C=B.cast(D.dllhandle,B.c_void_p);A=B.create_unicode_buffer(32768);E=B.windll.kernel32.GetModuleFileNameW(C,A,J(A))\n  if E==J(A):return H\n  return A.value\n@O\ndef a(suffix=F):\n  if G:yield Z()\n  E=[];M(E,C('LIBPL'));M(E,C('srcdir'));M(E,C('LIBDIR'))\n  if G or I or L:E.append(A.path.join(A.path.dirname(D.executable)))\n  else:E.append(A.path.join(A.path.dirname(A.path.dirname(D.executable)),K))\n  M(E,C('PYTHONFRAMEWORKPREFIX'));E.append(D.exec_prefix);E.append(A.path.join(D.exec_prefix,K));H=list(Y(suffix=suffix))\n  if R and not I:\n    for F in H:\n      try:J=B.CDLL(F)\n      except OSError:pass\n      else:yield V(J)\n  for N in E:\n    for F in H:yield A.path.join(N,F)\n  for F in H:yield Q(W(F))\ndef S(path,suffix=F,_is_apple=N):\n  C=suffix;B=path\n  if not B:return H\n  if not A.path.isabs(B):return H\n  if A.path.exists(B):return A.path.realpath(B)\n  if A.path.exists(B+C):return A.path.realpath(B+C)\n  if _is_apple:return S(b(B),suffix=P,_is_apple=False)\n  return H\ndef b(path):\n  A=path\n  if A.endswith(T):return A[:-J(T)]\n  if A.endswith(P):return A[:-J(P)]\n  return A\n@O\ndef c():\n  E.debug('_is_windows = %s',G);E.debug('_is_apple = %s',N);E.debug('_is_mingw = %s',L);E.debug('_is_msys = %s',I);E.debug('_is_posix = %s',R)\n  for B in a():\n    E.debug('Candidate: %s',B);A=S(B)\n    if A:E.debug('Found: %s',A);yield A\n    else:E.debug('Not found.')\ndef d():\n  for B in c():return A.path.realpath(B)\ndef f(items):\n  for A in items:e(A)\ne(d())"

var pythonPath = getEnv("RC_LIBPYTHON")

if pythonPath == "":
  when hostOS == "windows":
    var p = execCmdEx(&"python.exe -c \"{findLibpython}\"")
  else:
    var p = execCmdEx(&"python -c \"{findLibpython}\"")
  if p.exitCode != 0:
    when hostOS == "windows":
      p = execCmdEx(&"python3.exe -c \"{findLibpython}\"")
    else:
      p = execCmdEx(&"python3 -c \"{findLibpython}\"")
    if p.exitCode != 0:
      echo "error while trying to find libpython"
      quit(1)
  pythonPath = p.output[0..^2]

let hasPython = try:
  pyInitLibPath(pythonPath)
  true
except:
  false

proc validate*(config: JsonNode, registry = "", version = "") =
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

  var foundTrue = false
  for k, v in config["build"]:
    if v.getBool():
      foundTrue = true
      break

  if not foundTrue:
    echo "No option is enabled in the 'build' section."
    quit(1)

  if version != "":
    config{"renutil", "version"} = %version
  elif config{"renutil", "version"}.getStr() == "latest":
    config{"renutil", "version"} = %($listAvailable()[0])

  let renpyVersion = config{"renutil", "version"}.getStr()

  if parseVersion(renpyVersion) notin listAvailable():
    echo &"Ren'Py version {renpyVersion} does not exist."
    quit(1)

  echo &"Using Ren'Py version {renpyVersion}"

  if config{"build", "web"}.getBool() and renpyVersion < "7.3.0":
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

  let taskDir = config["options"]["task_dir"].getStr()
  if taskDir != "" and not dirExists(taskDir):
    echo &"Task directory '{task_dir}' does not exist."
    quit(1)

proc build*(
  inputDir: string,
  outputDir: string,
  config: string,
  registry = "",
  version = "",
) =
  ## Builds a Ren'Py project with the specified configuration.
  var
    taskCount = 0
    registryPath: string
    renutilTargetVersion: Version
    tasks = initTable[string, seq[Task]]()

  tasks["pre"] = @[]
  tasks["post"] = @[]

  var config = parsetoml.parseFile(config).convertToJson()

  config.validate(registry, version)

  let activeBuilds = block:
    var builds: seq[string]
    for k, v in config["build"]:
      if v.getBool():
        builds.add(k)
    let result = toHashSet(builds)
    result

  if hasPython:
    let pysys = pyImport("sys")
    echo &"Python Support: true"
    echo &"Python Version: {pysys.version.to(string)}"

    let taskDir = config{"options", "task_dir"}.getStr()
    if taskDir != "":
      let py = pyBuiltinsModule()
      let inspect = pyImport("inspect")

      discard pysys.path.append(taskDir)

      echo &"Scanning tasks in directory '{taskDir}'..."

      for file in walkDirRec(taskDir):
        if not file.endsWith(".py"):
          continue

        let (dir, name, _) = splitFile(relativePath(file, taskDir))
        let importPath = joinPath(dir, name).replace($DirSep, ".")
        let module = pyImport(importPath.cstring)

        for info in inspect.getmembers(module, inspect.isclass):
          let
            name = info[0].to(string)
            class = info[1]

          if not name.endsWith("Task") or name == "Task":
            continue

          let configName = name[0..^5].toSnakeCase()
          var subConfig = config{"tasks", configName}

          if py.hasattr(class, "validate_config").to(bool):
            try:
              if subConfig == nil:
                config{"tasks", configName} = class.validateConfig(%*{}).to(JsonNode)
              else:
                config{"tasks", configName} = class.validateConfig(subConfig).to(JsonNode)
            except:
              echo &"Failed to validate config for task {name}: {getCurrentExceptionMsg()}"
              quit(1)

          subConfig = config{"tasks", configName}

          if not subConfig{"enabled"}.getBool():
            continue

          taskCount += 1

          # create new instance
          let instance = class.callMethod("__new__", class, config)
          # init instance
          discard class.callMethod("__init__", instance, config, inputDir, outputDir)

          let builds = block:
            var results = block:
              var builds: seq[string]
              for k, v in config["build"]:
                builds.add(k)
              builds
            let result = subConfig{"on_builds"}.getElems().mapIt(it.getStr())
            if result.len > 0:
              results = result
            results

          if py.hasattr(instance, "pre_build").to(bool):
            tasks["pre"].add(
              Task(
                name: configName,
                instance: instance,
                builds: builds,
                priority: subConfig{"priorities", "pre_build"}.getInt(0),
              )
            )

          if py.hasattr(instance, "post_build").to(bool):
            tasks["post"].add(
              Task(
                name: configName,
                instance: instance,
                builds: builds,
                priority: subConfig{"priorities", "post_build"}.getInt(0),
              )
            )

          echo &"Loaded Task: {name}"
  else:
    echo "Python Support: false"

  if config{"tasks", "clean", "enabled"}.getBool():
    tasks["post"].add(
      Task(
        name: "clean",
        call: taskPostClean,
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
    taskCount += 1
    echo &"Loaded Task: clean"

  if config{"tasks", "notarize", "enabled"}.getBool():
    tasks["post"].add(
      Task(
        name: "notarize",
        call: taskPostNotarize,
        builds: block:
          var results = @["mac"]
          let result = config{"tasks", "notarize", "on_builds"}.getElems().mapIt(it.getStr())
          if result.len > 0:
            results = result
          results,
        priority: config{"tasks", "notarize", "priorities", "post_build"}.getInt(10),
      )
    )
    taskCount += 1
    echo &"Loaded Task: notarize"

  if config{"tasks", "convert_images", "enabled"}.getBool():
    tasks["pre"].add(
      Task(
        name: "convert_images",
        call: taskPreConvertImages,
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
    taskCount += 1
    echo &"Loaded Task: convert_images"

  if config{"tasks", "keystore", "enabled"}.getBool():
    tasks["pre"].add(
      Task(
        name: "keystore",
        call: taskPreKeystore,
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
        call: taskPostKeystore,
        builds: block:
          var results = @["android_apk", "android_aab"]
          let result = config{"tasks", "keystore", "on_builds"}.getElems().mapIt(it.getStr())
          if result.len > 0:
            results = result
          results,
        priority: config{"tasks", "keystore", "priorities", "post_build"}.getInt(0),
      )
    )
    taskCount += 1
    echo &"Loaded Task: keystore"

  tasks["pre"] = tasks["pre"].sortedByIt((it.priority, it.name)).reversed()
  tasks["post"] = tasks["post"].sortedByIt((it.priority, it.name)).reversed()

  if taskCount == 1:
    echo "Loaded 1 task"
  else:
    echo &"Loaded {taskCount} tasks"

  if registry != "":
    registryPath = getRegistry(registry)
  elif "registry" in config["renutil"]:
    registryPath = getRegistry(config["renutil"]["registry"].getStr())
  else:
    registryPath = getRegistry(registry)

  if not dirExists(inputDir):
    echo &"Game directory '{inputDir}' does not exist."
    quit(1)

  if config["options"]["clear_output_dir"].getBool() and dirExists(outputDir):
    removeDir(outputDir)

  createDir(outputDir)

  if version != "":
    renutilTargetVersion = parseVersion(version)
  else:
    renutilTargetVersion = parseVersion(config["renutil"]["version"].getStr())

  if not isInstalled(renutilTargetVersion, registryPath):
    echo &"Installing Ren'Py {renutilTargetVersion}"
    install($renutilTargetVersion, registryPath)

  for task in tasks["pre"]:
    if (activeBuilds * task.builds.toHashSet).len == 0:
      continue
    echo &"Running pre-build task {task.name} with priority {task.priority}"
    if task.call != nil:
      task.call(config, inputDir, outputDir)
    else:
      discard task.instance.preBuild()

  if config["build"]["android_apk"].getBool() or
    config{"build", "android"}.getBool(): # for backwards-compatibility with older config files
    echo "Building Android APK package."
    if renutilTargetVersion >= newVersion(7, 4, 9):
      launch(
        $renutilTargetVersion,
        false,
        false,
        &"android_build {quoteShell(inputDir)} --dest {quoteShell(absolutePath(outputDir))}",
        registryPath
      )
    else:
      launch(
        $renutilTargetVersion,
        false,
        false,
        &"android_build {quoteShell(inputDir)} assembleRelease --dest {quoteShell(absolutePath(outputDir))}",
        registryPath
      )

  if config["build"]["android_aab"].getBool():
    echo "Building Android AAB package."
    if renutilTargetVersion >= newVersion(7, 4, 9):
      launch(
        $renutilTargetVersion,
        false,
        false,
        &"android_build {quoteShell(inputDir)} --bundle --dest {quoteShell(absolutePath(outputDir))}",
        registryPath
      )
    else:
      echo "Not supported for Ren'Py versions <7.4.9"
      quit(1)

  var platformsToBuild: seq[string]
  if "pc" in config["build"] and config["build"]["pc"].getBool():
    platformsToBuild.add("pc")
  if "mac" in config["build"] and config["build"]["mac"].getBool():
    platformsToBuild.add("mac")
  if "win" in config["build"] and config["build"]["win"].getBool():
    platformsToBuild.add("win")
  if "linux" in config["build"] and config["build"]["linux"].getBool():
    platformsToBuild.add("linux")
  if "market" in config["build"] and config["build"]["market"].getBool():
    platformsToBuild.add("market")
  if "steam" in config["build"] and config["build"]["steam"].getBool():
    platformsToBuild.add("steam")
  if "web" in config["build"] and config["build"]["web"].getBool():
    # make out_dir = {project-name}-{version}-web directory in output directory
    # modify build command:
    # --destination {out_dir} --packagedest joinPath(out_dir, "game") --package web --no-archive
    # TODO: somehow trigger repack_for_progressive_download()
    # copy files from {version}/web except for hash.txt to the web output directory
    # modify index.html and replace %%TITLE%% with the game's display name
    platformsToBuild.add("web")

  if len(platformsToBuild) > 0:
    var cmd = &"distribute {quoteShell(inputDir)} --destination {quoteShell(absolutePath(outputDir))}"
    for package in platformsToBuild:
      cmd = cmd & &" --package {package}"
    let joinedPackages = join(platformsToBuild, ", ")

    echo &"Building {joinedPackages} packages."
    launch(
      $renutilTargetVersion,
      false,
      false,
      cmd,
      registryPath
    )

  for task in tasks["post"]:
    if (activeBuilds * task.builds.toHashSet).len == 0:
      continue
    echo &"Running post-build task {task.name} with priority {task.priority}"
    if task.call != nil:
      task.call(config, inputDir, outputDir)
    else:
      discard task.instance.postBuild()

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
