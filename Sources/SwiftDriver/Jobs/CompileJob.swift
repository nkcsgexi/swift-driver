//===--------------- CompileJob.swift - Swift Compilation Job -------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import TSCBasic
import SwiftOptions

extension Driver {
  /// Add the appropriate compile mode option to the command line for a compile job.
  mutating func addCompileModeOption(outputType: FileType?, commandLine: inout [Job.ArgTemplate]) {
    if let compileOption = outputType?.frontendCompileOption {
      commandLine.appendFlag(compileOption)
    } else {
      guard let compileModeOption = parsedOptions.getLast(in: .modes) else {
        fatalError("We were told to perform a standard compile, but no mode option was passed to the driver.")
      }

      commandLine.appendFlag(compileModeOption.option)
    }
  }

  mutating func computePrimaryOutput(for input: TypedVirtualPath, outputType: FileType,
                                        isTopLevel: Bool) -> TypedVirtualPath {
    if let path = outputFileMap?.existingOutput(inputFile: input.file, outputType: outputType) {
      return TypedVirtualPath(file: path, type: outputType)
    }

    if isTopLevel {
      if let baseOutput = parsedOptions.getLastArgument(.o)?.asSingle,
         let baseOutputPath = try? VirtualPath(path: baseOutput) {
        return TypedVirtualPath(file: baseOutputPath, type: outputType)
      } else if compilerOutputType?.isTextual == true {
        return TypedVirtualPath(file: .standardOutput, type: outputType)
      }
    }

    let baseName: String
    if !compilerMode.usesPrimaryFileInputs && numThreads == 0 {
      baseName = moduleOutputInfo.name
    } else {
      baseName = input.file.basenameWithoutExt
    }

    if !isTopLevel {
      return TypedVirtualPath(file:VirtualPath.temporary(.init(baseName.appendingFileTypeExtension(outputType))),
                              type: outputType)
    }
    return TypedVirtualPath(file: useWorkingDirectory(.init(baseName.appendingFileTypeExtension(outputType))), type: outputType)
  }

  /// Is this compile job top-level
  func isTopLevelOutput(type: FileType?) -> Bool {
    switch type {
    case .assembly, .sil, .raw_sil, .llvmIR, .ast, .jsonDependencies, .sib, .raw_sib,
         .importedModules, .indexData:
      return true
    case .object:
      return (linkerOutputType == nil)
    case .llvmBitcode:
      if compilerOutputType != .llvmBitcode {
        // The compiler output isn't bitcode, so bitcode isn't top-level (-embed-bitcode).
        return false
      } else {
        // When -lto is set, .bc will be used for linking. Otherwise, .bc is
        // top-level output (-emit-bc)
        return lto == nil
      }
    case .swiftModule:
      return compilerMode.isSingleCompilation && moduleOutputInfo.output?.isTopLevel ?? false
    case .swift, .image, .dSYM, .dependencies, .autolink, .swiftDocumentation, .swiftInterface,
         .privateSwiftInterface, .swiftSourceInfoFile, .diagnostics, .objcHeader, .swiftDeps,
         .remap, .tbd, .moduleTrace, .yamlOptimizationRecord, .bitstreamOptimizationRecord, .pcm,
         .pch, .clangModuleMap, .jsonTargetInfo, .jsonSwiftArtifacts, .jsonClangDependencies, nil:
      return false
    }
  }

  /// Add the compiler inputs for a frontend compilation job, and return the
  /// corresponding primary set of outputs.
  mutating func addCompileInputs(primaryInputs: [TypedVirtualPath],
                                 indexFilePath: TypedVirtualPath?,
                                 inputs: inout [TypedVirtualPath],
                                 inputOutputMap: inout [TypedVirtualPath: TypedVirtualPath],
                                 outputType: FileType?,
                                 commandLine: inout [Job.ArgTemplate]) -> [TypedVirtualPath] {
    // Collect the set of input files that are part of the Swift compilation.
    let swiftInputFiles: [TypedVirtualPath] = inputFiles.filter { $0.type.isPartOfSwiftCompilation }

    let useInputFileList: Bool
    if let allSourcesFileList = allSourcesFileList {
      useInputFileList = true
      commandLine.appendFlag(.filelist)
      commandLine.appendPath(allSourcesFileList)
    } else {
      useInputFileList = false
    }

    let usePrimaryInputFileList = primaryInputs.count > fileListThreshold
    if usePrimaryInputFileList {
      // primary file list
      commandLine.appendFlag(.primaryFilelist)
      let path = RelativePath(createTemporaryFileName(prefix: "primaryInputs"))
      commandLine.appendPath(.fileList(path, .list(primaryInputs.map(\.file))))
    }

    let isTopLevel = isTopLevelOutput(type: outputType)

    // If we will be passing primary files via -primary-file, form a set of primary input files so
    // we can check more quickly.
    let usesPrimaryFileInputs: Bool
    let primaryInputFiles: Set<TypedVirtualPath>
    if compilerMode.usesPrimaryFileInputs {
      assert(!primaryInputs.isEmpty)
      usesPrimaryFileInputs = true
      primaryInputFiles = Set(primaryInputs)
    } else if let path = indexFilePath {
      // If -index-file is used, we perform a single compile but pass the
      // -index-file-path as a primary input file.
      usesPrimaryFileInputs = true
      primaryInputFiles = [path]
    } else {
      usesPrimaryFileInputs = false
      primaryInputFiles = []
    }

    let isMultithreaded = numThreads > 0

    // Add each of the input files.
    var primaryOutputs: [TypedVirtualPath] = []
    for input in swiftInputFiles {
      inputs.append(input)

      let isPrimary = usesPrimaryFileInputs && primaryInputFiles.contains(input)
      if isPrimary {
        if !usePrimaryInputFileList {
          commandLine.appendFlag(.primaryFile)
          commandLine.appendPath(input.file)
        }
      } else {
        if !useInputFileList {
          commandLine.appendPath(input.file)
        }
      }

      // If there is a primary output or we are doing multithreaded compiles,
      // add an output for the input.
      if let outputType = outputType,
        isPrimary || (!usesPrimaryFileInputs && isMultithreaded && outputType.isAfterLLVM) {
        let output = computePrimaryOutput(for: input,
                                          outputType: outputType,
                                          isTopLevel: isTopLevel)
        primaryOutputs.append(output)
        inputOutputMap[input] = output
      }
    }

    // When not using primary file inputs or multithreading, add a single output.
    if let outputType = outputType,
       !usesPrimaryFileInputs && !(isMultithreaded && outputType.isAfterLLVM) {
      let input = TypedVirtualPath(file: OutputFileMap.singleInputKey, type: swiftInputFiles[0].type)
      let output = computePrimaryOutput(for: input,
                                        outputType: outputType,
                                        isTopLevel: isTopLevel)
      primaryOutputs.append(output)
      inputOutputMap[input] = output
    }

    return primaryOutputs
  }

  /// Form a compile job, which executes the Swift frontend to produce various outputs.
  mutating func compileJob(primaryInputs: [TypedVirtualPath],
                           outputType: FileType?,
                           addJobOutputs: ([TypedVirtualPath]) -> Void,
                           emitModuleTrace: Bool)
  throws -> Job {
    var commandLine: [Job.ArgTemplate] = swiftCompilerPrefixArgs.map { Job.ArgTemplate.flag($0) }
    var inputs: [TypedVirtualPath] = []
    var outputs: [TypedVirtualPath] = []
    // Used to map primaryInputs to primaryOutputs
    var inputOutputMap = [TypedVirtualPath: TypedVirtualPath]()

    commandLine.appendFlag("-frontend")
    addCompileModeOption(outputType: outputType, commandLine: &commandLine)

    let indexFilePath: TypedVirtualPath?
    if let indexFileArg = parsedOptions.getLastArgument(.indexFilePath)?.asSingle {
      let path = try VirtualPath(path: indexFileArg)
      indexFilePath = inputFiles.first { $0.file == path }
    } else {
      indexFilePath = nil
    }

    let primaryOutputs = addCompileInputs(primaryInputs: primaryInputs,
                                          indexFilePath: indexFilePath,
                                          inputs: &inputs,
                                          inputOutputMap: &inputOutputMap,
                                          outputType: outputType,
                                          commandLine: &commandLine)
    outputs += primaryOutputs

    // FIXME: optimization record arguments are added before supplementary outputs
    // for compatibility with the integrated driver's test suite. We should adjust the tests
    // so we can organize this better.
    // -save-optimization-record and -save-optimization-record= have different meanings.
    // In this case, we specifically want to pass the EQ variant to the frontend
    // to control the output type of optimization remarks (YAML or bitstream).
    try commandLine.appendLast(.saveOptimizationRecordEQ, from: &parsedOptions)
    try commandLine.appendLast(.saveOptimizationRecordPasses, from: &parsedOptions)

    outputs += try addFrontendSupplementaryOutputArguments(
      commandLine: &commandLine,
      primaryInputs: primaryInputs,
      inputOutputMap: inputOutputMap,
      includeModuleTracePath: emitModuleTrace)

    // Forward migrator flags.
    try commandLine.appendLast(.apiDiffDataFile, from: &parsedOptions)
    try commandLine.appendLast(.apiDiffDataDir, from: &parsedOptions)
    try commandLine.appendLast(.dumpUsr, from: &parsedOptions)

    if parsedOptions.hasArgument(.parseStdlib) {
      commandLine.appendFlag(.disableObjcAttrRequiresFoundationModule)
    }

    try addCommonFrontendOptions(commandLine: &commandLine, inputs: &inputs)
    // FIXME: MSVC runtime flags

    if parsedOptions.hasArgument(.parseAsLibrary, .emitLibrary) {
      commandLine.appendFlag(.parseAsLibrary)
    }

    try commandLine.appendLast(.parseSil, from: &parsedOptions)

    try commandLine.appendLast(.migrateKeepObjcVisibility, from: &parsedOptions)

    if numThreads > 0 {
      commandLine.appendFlags("-num-threads", numThreads.description)
    }

    // Add primary outputs.
    if primaryOutputs.count > fileListThreshold {
      commandLine.appendFlag(.outputFilelist)
      let path = RelativePath(createTemporaryFileName(prefix: "outputs"))
      commandLine.appendPath(.fileList(path, .list(primaryOutputs.map { $0.file })))
    } else {
      for primaryOutput in primaryOutputs {
        commandLine.appendFlag(.o)
        commandLine.appendPath(primaryOutput.file)
      }
    }

    try commandLine.appendLast(.embedBitcodeMarker, from: &parsedOptions)

    // For `-index-file` mode add `-disable-typo-correction`, since the errors
    // will be ignored and it can be expensive to do typo-correction.
    if compilerOutputType == FileType.indexData {
      commandLine.appendFlag(.disableTypoCorrection)
    }

    if parsedOptions.contains(.indexStorePath) {
      try commandLine.appendLast(.indexStorePath, from: &parsedOptions)
      if !parsedOptions.contains(.indexIgnoreSystemModules) {
        commandLine.appendFlag(.indexSystemModules)
      }
    }

    if parsedOptions.contains(.debugInfoStoreInvocation) ||
       toolchain.shouldStoreInvocationInDebugInfo {
      commandLine.appendFlag(.debugInfoStoreInvocation)
    }

    try commandLine.appendLast(.trackSystemDependencies, from: &parsedOptions)
    try commandLine.appendLast(.CrossModuleOptimization, from: &parsedOptions)
    try commandLine.appendLast(.disableAutolinkingRuntimeCompatibility, from: &parsedOptions)
    try commandLine.appendLast(.runtimeCompatibilityVersion, from: &parsedOptions)
    try commandLine.appendLast(.disableAutolinkingRuntimeCompatibilityDynamicReplacements, from: &parsedOptions)

    addJobOutputs(outputs)

    // If we're creating emit module job, order the compile jobs after that.
    if shouldCreateEmitModuleJob {
      inputs.append(TypedVirtualPath(file: moduleOutputInfo.output!.outputPath, type: .swiftModule))
    }

    // Bridging header is needed for compiling these .swift sources.
    if let pchPath = bridgingPrecompiledHeader {
      inputs.append(TypedVirtualPath(file: pchPath, type: .pch))
    }
    return Job(
      moduleName: moduleOutputInfo.name,
      kind: .compile,
      tool: .absolute(try toolchain.getToolPath(.swiftCompiler)),
      commandLine: commandLine,
      displayInputs: primaryInputs,
      inputs: inputs,
      primaryInputs: primaryInputs,
      outputs: outputs,
      supportsResponseFiles: true
    )
  }
}

extension FileType {
  /// Determine the frontend compile option that corresponds to the given output type.
  fileprivate var frontendCompileOption: Option {
    switch self {
    case .object:
      return .c
    case .pch:
      return .emitPch
    case .ast:
      return .dumpAst
    case .raw_sil:
      return .emitSilgen
    case .sil:
      return .emitSil
    case .raw_sib:
      return .emitSibgen
    case .sib:
      return .emitSib
    case .llvmIR:
      return .emitIr
    case .llvmBitcode:
      return .emitBc
    case .assembly:
      return .S
    case .swiftModule:
      return .emitModule
    case .importedModules:
      return .emitImportedModules
    case .indexData:
      return .typecheck
    case .remap:
      return .updateCode
    case .jsonDependencies:
      return .scanDependencies
    case .jsonClangDependencies:
      return .scanClangDependencies
    case .jsonTargetInfo:
      return .printTargetInfo

    case .swift, .dSYM, .autolink, .dependencies, .swiftDocumentation, .pcm,
         .diagnostics, .objcHeader, .image, .swiftDeps, .moduleTrace, .tbd,
         .yamlOptimizationRecord, .bitstreamOptimizationRecord, .swiftInterface,
         .privateSwiftInterface, .swiftSourceInfoFile, .clangModuleMap, .jsonSwiftArtifacts:
      fatalError("Output type can never be a primary output")
    }
  }
}
