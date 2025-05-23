import 'dart:io';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:path/path.dart';
import 'package:riverpod/riverpod.dart';

import 'config/config_loader.dart';
import 'repo_entry.dart';
import 'task_base.dart';
import 'tasks/provider/task_loader.dart';
import 'util/file_resolver.dart';
import 'util/logger.dart';
import 'util/program_runner.dart';

part 'hooks.freezed.dart';

// coverage:ignore-start
/// A riverpod provider for the [Hooks] class, configurable with the
/// [HooksConfig].
final hooksProvider = Provider.family(
  (ref, HooksConfig config) => Hooks(
    fileResolver: ref.watch(fileResolverProvider),
    programRunner: ref.watch(programRunnerProvider),
    configLoader: ref.watch(configLoaderProvider),
    taskLoader: ref.watch(taskLoaderProvider),
    logger: ref.watch(loggerProvider),
    config: config,
  ),
);
// coverage:ignore-end

/// A configuration class for launching the [Hooks] instance.
@freezed
sealed class HooksConfig with _$HooksConfig {
  /// Default constructor
  const factory HooksConfig({
    /// Specifies, whether processing should continue on rejections.
    ///
    /// Normally, once one of the hook operations detects an unfixable problem,
    /// the whole process is aborted with [HookResult.rejected]. If however
    /// [continueOnRejected] is set to true, instead processing will continue as
    /// usual. In both cases, the hooks will resolve with [HookResult.rejected].
    @Default(false) bool continueOnRejected,

    /// Specifies the path to the configuration file.
    ///
    /// If not specified, the tool tries to read the configuration from the
    /// pubspec.yaml. This will work as long as the pubspec is located in the
    /// root directory of the directory that is being scanned. It will check for
    /// entries under `dart_pre_commit` in the file.
    ///
    /// If a custom path is given, it is expected that this file directly
    /// contains the configuration as root level elements (without the
    /// `dart_pre_commit`).
    String? configFile,
  }) = _HooksConfig;
}

/// The result of a [Hooks] call.
enum HookResult {
  /// All is ok, nothing was modified.
  clean(0),

  /// Files had to be fixed up, but all succeeded and only fully staged files
  /// were affected.
  hasChanges(1),

  /// Files had to be fixed up, all succeeded but partially staged files had to
  /// be modified.
  hasUnstagedChanges(2),

  /// At least one hook detected a problem that has to be fixed manually before
  /// the commit can be accepted
  rejected(3);

  /// @nodoc
  @internal
  final int exitCode;

  /// @nodoc
  @internal
  const HookResult(this.exitCode);

  /// Returns a boolean that indicates whether the result should be treated as
  /// success or as failure.
  ///
  /// The following table lists how result codes are interpreted:
  ///
  /// Code                            | Success
  /// --------------------------------|---------
  /// [HookResult.clean]              | true
  /// [HookResult.hasChanges]         | true
  /// [HookResult.hasUnstagedChanges] | false
  /// [HookResult.rejected]           | false
  bool get isSuccess => index <= HookResult.hasChanges.index;

  HookResult _raiseTo(HookResult target) =>
      target.index > index ? target : this;

  TaskStatus _toStatus() {
    switch (this) {
      case HookResult.clean:
        return TaskStatus.clean;
      case HookResult.hasChanges:
        return TaskStatus.hasChanges;
      case HookResult.hasUnstagedChanges:
        return TaskStatus.hasUnstagedChanges;
      case HookResult.rejected:
        return TaskStatus.rejected;
    }
  }
}

extension _HookResultStreamX on Stream<HookResult> {
  Future<HookResult> raise([HookResult base = HookResult.clean]) =>
      fold(base, (previous, element) => previous._raiseTo(element));
}

class _RejectedException implements Exception {
  const _RejectedException();
}

/// A callable class the runs the hooks on a repository.
///
/// This is the main entrypoint of the library. The class will scan your
/// repository for staged files and run all activated hooks on them, reporting
/// a result.
class Hooks {
  final FileResolver _fileResolver;
  final ProgramRunner _programRunner;
  final ConfigLoader _configLoader;
  final TaskLoader _taskLoader;

  final Logger _logger;

  /// The configuration used by this instance.
  final HooksConfig config;

  /// Constructs a new [Hooks] instance.
  ///
  /// The [fileResolver], [programRunner], [configLoader], [taskLoader] and
  /// [logger] are needed internally by this class. Use the [hooksProvider] for
  /// an easy initialization.
  ///
  /// The [config] can be used to control custom behavior. See [HooksConfig] for
  /// more details.
  const Hooks({
    required FileResolver fileResolver,
    required ProgramRunner programRunner,
    required ConfigLoader configLoader,
    required TaskLoader taskLoader,
    required Logger logger,
    this.config = const HooksConfig(),
  }) : _fileResolver = fileResolver,
       _programRunner = programRunner,
       _configLoader = configLoader,
       _taskLoader = taskLoader,
       _logger = logger;

  /// Executes all enabled hooks on the current repository.
  ///
  /// The command will run expecting [Directory.current] to be the dart project
  /// root withing the enclosing git repository to be processed. It collects all
  /// staged files and then runs all enabled hooks on these files.
  ///
  /// The result is determined based on the collective result of all processed
  /// files and hooks. A [HookResult.clean] result is only possible if all
  /// operations are clean. If at least one staged file had to modified, the
  /// result is [HookResult.hasChanges]. If at least one file was partially
  /// staged, it will be [HookResult.hasUnstagedChanges] instead. The
  /// [HookResult.rejected] will be the result if any task finds at least one
  /// file with problems that cannot be fixed automatically.
  Future<HookResult> call() async {
    try {
      final configFile =
          config.configFile != null
              ? _fileResolver.file(config.configFile!)
              : null;
      final enabled = await _configLoader.loadGlobalConfig(configFile);

      if (!enabled) {
        _logger.info(
          'dart_pre_commit has been disabled via the configuration.',
        );
        return HookResult.clean;
      }

      final tasks = _taskLoader.loadTasks().toList();

      final entries = await _collectStagedFiles().toList();
      if (entries.isEmpty) {
        return HookResult.clean;
      }

      var lintState = HookResult.clean;
      lintState = await Stream.fromIterable(
        entries,
      ).asyncMap((e) => _scanEntry(tasks, e)).raise(lintState);
      lintState = await Stream.fromIterable(
        tasks.whereType<RepoTask>(),
      ).asyncMap((task) => _evaluateRepoTask(task, entries)).raise(lintState);

      return lintState;
    } on _RejectedException {
      return HookResult.rejected;
    }
  }

  Future<HookResult> _scanEntry(List<TaskBase> tasks, RepoEntry entry) async {
    try {
      _logger.updateStatus(
        message: 'Scanning ${entry.file.path}...',
        status: TaskStatus.scanning,
        refresh: false,
      );
      var scanResult = TaskResult.accepted;
      for (final task in tasks.whereType<FileTask>()) {
        if (task.canProcess(entry)) {
          final taskResult = await _runFileTask(task, entry);
          scanResult = scanResult.raiseTo(taskResult);
        }
      }
      final hookResult = await _processTaskResult(scanResult, entry);
      _logFileTaskResult(hookResult, entry);
      return hookResult;
    } on _RejectedException {
      _logFileTaskResult(HookResult.rejected, entry);
      rethrow;
    } finally {
      _logger.completeStatus();
    }
  }

  Future<TaskResult> _runFileTask(FileTask task, RepoEntry entry) async {
    _logger.updateStatus(detail: '[${task.taskName}]');
    final taskResult = await task(entry);
    _checkTaskRejected(taskResult);
    return taskResult;
  }

  void _logFileTaskResult(HookResult hookResult, RepoEntry entry) {
    String message;
    switch (hookResult) {
      case HookResult.clean:
        message = 'Accepted file ${entry.file.path}';
      case HookResult.hasChanges:
        message = 'Fixed up ${entry.file.path}';
      case HookResult.hasUnstagedChanges:
        message = 'Fixed up partially staged file ${entry.file.path}';
      case HookResult.rejected:
        message = 'Rejected file ${entry.file.path}';
    }
    _logger.updateStatus(
      status: hookResult._toStatus(),
      message: message,
      clear: true,
    );
  }

  Future<HookResult> _evaluateRepoTask(
    RepoTask task,
    List<RepoEntry> entries,
  ) async {
    final filteredEntries = entries.where(task.canProcess).toList();
    if (filteredEntries.isNotEmpty || task.callForEmptyEntries) {
      return _runRepoTask(task, filteredEntries);
    } else {
      return HookResult.clean;
    }
  }

  Future<HookResult> _runRepoTask(
    RepoTask task,
    List<RepoEntry> entries,
  ) async {
    try {
      _logger.updateStatus(
        message: 'Running ${task.taskName}...',
        status: TaskStatus.scanning,
      );
      final taskResult = await task(entries);
      _checkTaskRejected(taskResult);
      final hookResult = await _processMultiTaskResult(taskResult, entries);
      _logRepoTaskResult(hookResult, task);
      return hookResult;
    } on _RejectedException {
      _logRepoTaskResult(HookResult.rejected, task);
      rethrow;
    } finally {
      _logger.completeStatus();
    }
  }

  void _logRepoTaskResult(HookResult hookResult, RepoTask task) {
    String message;
    switch (hookResult) {
      case HookResult.clean:
        message = 'Completed ${task.taskName}';
      case HookResult.hasChanges:
        message = 'Completed ${task.taskName}, fixed up some files';
      case HookResult.hasUnstagedChanges:
        message =
            'Completed ${task.taskName}, fixed up some partially staged files';
      case HookResult.rejected:
        message = 'Completed ${task.taskName}, found problems';
    }
    _logger.updateStatus(
      status: hookResult._toStatus(),
      message: message,
      clear: true,
    );
  }

  void _checkTaskRejected(TaskResult result) {
    if (!config.continueOnRejected && result == TaskResult.rejected) {
      throw const _RejectedException();
    }
  }

  Future<HookResult> _processTaskResult(
    TaskResult taskResult,
    RepoEntry? entry,
  ) async {
    switch (taskResult) {
      case TaskResult.accepted:
        return HookResult.clean;
      case TaskResult.modified:
        if (entry?.partiallyStaged ?? false) {
          return HookResult.hasUnstagedChanges;
        } else {
          if (entry != null) {
            await _programRunner.stream('git', [
              'add',
              entry.file.path,
            ]).drain<void>();
          }
          return HookResult.hasChanges;
        }
      case TaskResult.rejected:
        assert(config.continueOnRejected, 'continueOnRejected must be true');
        return HookResult.rejected;
    }
  }

  Future<HookResult> _processMultiTaskResult(
    TaskResult taskResult,
    List<RepoEntry> entries,
  ) async {
    if (entries.isEmpty) {
      return await _processTaskResult(taskResult, null);
    } else {
      return await Stream.fromIterable(
        entries,
      ).asyncMap((entry) => _processTaskResult(taskResult, entry)).raise();
    }
  }

  Stream<RepoEntry> _collectStagedFiles() async* {
    final gitRoot = await _gitRoot();
    final indexChanges =
        await _streamGitFiles(gitRoot, ['diff', '--name-only']).toList();
    final stagedChanges = _streamGitFiles(gitRoot, [
      'diff',
      '--name-only',
      '--cached',
    ]);
    final excludedFiles = _configLoader.loadExcludePatterns();

    await for (final path in stagedChanges) {
      final file = _fileResolver.file(path);
      if (!file.existsSync()) {
        continue;
      }
      if (excludedFiles.any((pattern) => pattern.hasMatch(file.path))) {
        continue;
      }
      yield RepoEntry(
        file: file,
        partiallyStaged: indexChanges.contains(path),
        gitRoot: Directory(gitRoot),
      );
    }
  }

  Future<String> _gitRoot() async =>
      Directory(
        await _programRunner.stream('git', const [
          'rev-parse',
          '--show-toplevel',
        ]).first,
      ).resolveSymbolicLinks();

  Stream<String> _streamGitFiles(
    String gitRoot,
    List<String> arguments,
  ) async* {
    final resolvedCurrent = await Directory.current.resolveSymbolicLinks();
    yield* _programRunner
        .stream('git', arguments)
        .map((path) => join(gitRoot, path))
        .where((path) => isWithin(resolvedCurrent, path))
        .map((path) => relative(path, from: resolvedCurrent));
  }
}
