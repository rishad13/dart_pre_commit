import 'dart:convert';

import 'package:dart_pre_commit/src/task_base.dart';
import 'package:dart_pre_commit/src/tasks/analysis_task_base.dart';
import 'package:dart_pre_commit/src/tasks/models/analyze/analyze_result.dart';
import 'package:dart_pre_commit/src/tasks/models/analyze/diagnostic.dart';
import 'package:dart_pre_commit/src/tasks/models/analyze/location.dart';
import 'package:dart_pre_commit/src/util/file_resolver.dart';
import 'package:dart_pre_commit/src/util/logger.dart';
import 'package:dart_pre_commit/src/util/program_runner.dart';
import 'package:dart_test_tools/test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../global_mocks.dart';

class MockProgramRunner extends Mock implements ProgramRunner {}

class MockFileResolver extends Mock implements FileResolver {}

class MockTaskLogger extends Mock implements TaskLogger {}

final class TestableAnalysisTaskBase extends AnalysisTaskBase {
  const TestableAnalysisTaskBase({
    required super.programRunner,
    required super.fileResolver,
    required super.logger,
    required super.config,
  });

  @override
  String get taskName => 'test-analysis-task';

  @override
  Iterable<String> get analysisCommand => ['test', 'command'];
}

const fullAnalyzeResult = AnalyzeResult(
  version: 1,
  diagnostics: [
    Diagnostic(
      code: 'A',
      severity: DiagnosticSeverity.error,
      type: DiagnosticType.syntacticError,
      location: Location(
        file: 'a.dart',
        range: Range(
          start: RangePosition(line: 10, column: 11, offset: 0),
          end: RangePosition(line: 10, column: 12, offset: 0),
        ),
      ),
      problemMessage: 'a1',
      correctionMessage: '1',
      documentation: null,
    ),
    Diagnostic(
      code: 'A',
      severity: DiagnosticSeverity.warning,
      type: DiagnosticType.syntacticError,
      location: Location(
        file: 'a-a-a.dart',
        range: Range(
          start: RangePosition(line: 88, column: 99, offset: 0),
          end: RangePosition(line: 99, column: 88, offset: 0),
        ),
      ),
      problemMessage: 'a2 - a2-a2',
      correctionMessage: '2',
      documentation: null,
    ),
    Diagnostic(
      code: 'B',
      severity: DiagnosticSeverity.info,
      type: DiagnosticType.syntacticError,
      location: Location(
        file: 'b/b.dart',
        range: Range(
          start: RangePosition(line: 30, column: 31, offset: 0),
          end: RangePosition(line: 32, column: 33, offset: 0),
        ),
      ),
      problemMessage: 'b3',
      correctionMessage: '3',
      documentation: null,
    ),
    Diagnostic(
      code: 'C',
      severity: DiagnosticSeverity.warning,
      type: DiagnosticType.syntacticError,
      location: Location(
        file: 'c/c/c.dart',
        range: Range(
          start: RangePosition(line: 40, column: 41, offset: 0),
          end: RangePosition(line: 42, column: 43, offset: 0),
        ),
      ),
      problemMessage: 'c4',
      correctionMessage: '4',
      documentation: null,
    ),
    Diagnostic(
      code: 'D',
      severity: DiagnosticSeverity.none,
      type: DiagnosticType.syntacticError,
      location: Location(
        file: 'pubspec.yaml',
        range: Range(
          start: RangePosition(line: 50, column: 51, offset: 0),
          end: RangePosition(line: 50, column: 51, offset: 0),
        ),
      ),
      problemMessage: 'd5',
      correctionMessage: '5',
      documentation: null,
    ),
  ],
);

const minimalAnalyzeResult = AnalyzeResult(
  version: 1,
  diagnostics: [
    Diagnostic(
      code: 'O',
      severity: DiagnosticSeverity.error,
      type: DiagnosticType.compileTimeError,
      location: Location(
        file: 'o.dart',
        range: Range(
          start: RangePosition(line: 0, column: 0, offset: 0),
          end: RangePosition(line: 1, column: 0, offset: 0),
        ),
      ),
      problemMessage: 'o',
      correctionMessage: null,
      documentation: null,
    ),
  ],
);

void main() {
  group('$AnalysisConfig', () {
    testData<(Map<String, dynamic>, AnalysisConfig)>(
      'correctly converts from json',
      [
        const (<String, dynamic>{}, AnalysisConfig()),
        const (
          <String, dynamic>{'error-level': 'warning'},
          AnalysisConfig(errorLevel: AnalyzeErrorLevel.warning),
        ),
      ],
      (fixture) {
        expect(AnalysisConfig.fromJson(fixture.$1), fixture.$2);
      },
    );
  });

  group('$AnalysisTaskBase', () {
    final mockLogger = MockTaskLogger();
    final mockRunner = MockProgramRunner();
    final mockResolver = MockFileResolver();

    late AnalysisTaskBase sut;

    void whenRunnerStream(Stream<String> stream, [int exitCode = 0]) => when(
      () => mockRunner.stream(
        any(),
        any(),
        failOnExit: any(named: 'failOnExit'),
        exitCodeHandler: any(named: 'exitCodeHandler'),
      ),
    ).thenAnswer((i) {
      final handler = i.namedArguments[#exitCodeHandler] as ExitCodeHandlerCb?;
      handler?.call(exitCode);
      return stream;
    });

    setUp(() {
      reset(mockLogger);
      reset(mockRunner);
      reset(mockResolver);

      whenRunnerStream(
        Stream.value(
          json.encode(const AnalyzeResult(version: 1, diagnostics: [])),
        ),
      );

      when(
        // ignore: discarded_futures
        () => mockResolver.resolve(any()),
      ).thenAnswer((i) async => i.positionalArguments.first as String);
      when(() => mockResolver.resolveAll(any())).thenAnswer(
        (i) => Stream.fromIterable(
          i.positionalArguments.first as Iterable<String>,
        ),
      );

      sut = TestableAnalysisTaskBase(
        logger: mockLogger,
        programRunner: mockRunner,
        fileResolver: mockResolver,
        config: const AnalysisConfig(),
      );
    });

    test('task metadata is correct', () {
      expect(sut.taskName, 'test-analysis-task');
      expect(sut.callForEmptyEntries, true);
    });

    testData<(String, bool)>(
      'matches only dart/pubspec.yaml files',
      const [
        ('test1.dart', true),
        ('test/path2.dart', true),
        ('test3.g.dart', true),
        ('test4.dart.g', false),
        ('test5_dart', false),
        ('test6.dat', false),
        ('pubspec.yaml', true),
        ('pubspec.yml', true),
        ('pubspec.lock', false),
        ('path/pubspec.yaml', false),
      ],
      (fixture) {
        expect(
          sut.filePattern.matchAsPrefix(fixture.$1),
          fixture.$2 ? isNotNull : isNull,
        );
      },
    );

    testData<(AnalyzeErrorLevel, List<String>)>(
      'Runs dart analyze with correct arguments',
      const [
        (AnalyzeErrorLevel.error, ['--no-fatal-warnings']),
        (AnalyzeErrorLevel.warning, ['--fatal-warnings']),
        (AnalyzeErrorLevel.info, ['--fatal-warnings', '--fatal-infos']),
      ],
      (fixture) async {
        sut = TestableAnalysisTaskBase(
          logger: mockLogger,
          programRunner: mockRunner,
          fileResolver: mockResolver,
          config: AnalysisConfig(errorLevel: fixture.$1),
        );

        final result = await sut([]);

        expect(result, TaskResult.accepted);
        verify(
          () => mockRunner.stream(
            'dart',
            ['test', 'command', '--format', 'json', ...fixture.$2],
            failOnExit: false,
            exitCodeHandler: any(named: 'exitCodeHandler', that: isNotNull),
          ),
        );
      },
    );

    group('collections lints for all files', () {
      setUp(() {
        sut = TestableAnalysisTaskBase(
          logger: mockLogger,
          programRunner: mockRunner,
          fileResolver: mockResolver,
          config: const AnalysisConfig(),
        );
      });

      test('collects lints for specified files', () async {
        whenRunnerStream(
          Stream.fromIterable([
            'this is an invalid line',
            '    this as well  ',
            json.encode(fullAnalyzeResult),
          ]),
        );

        final result = await sut([
          fakeEntry('a.dart'),
          fakeEntry('a-a-a.dart'),
          fakeEntry('b/b.dart'),
          fakeEntry('c/c/d.dart'),
          fakeEntry('pubspec.yaml'),
          fakeEntry('b/a.js'),
          fakeEntry('pipeline.yaml'),
        ]);
        expect(result, TaskResult.accepted);
        verifyInOrder([
          () => mockLogger.info('  error - a.dart:10:11 - a1 1 - A'),
          () => mockLogger.info(
            '  warning - a-a-a.dart:88:99 - a2 - a2-a2 2 - A',
          ),
          () => mockLogger.info('  info - b/b.dart:30:31 - b3 3 - B'),
          () => mockLogger.info('  warning - c/c/c.dart:40:41 - c4 4 - C'),
          () => mockLogger.info('  none - pubspec.yaml:50:51 - d5 5 - D'),
          () => mockLogger.info('5 issue(s) found.'),
        ]);
        verifyNever(() => mockLogger.info(any()));
      });

      test('fails if only exit code is set', () async {
        whenRunnerStream(Stream.value(json.encode(minimalAnalyzeResult)), 1);

        final result = await sut([fakeEntry('a.dart')]);
        expect(result, TaskResult.rejected);
        verifyInOrder([
          () => mockLogger.info('  error - o.dart:0:0 - o - O'),
          () => mockLogger.info('1 issue(s) found.'),
        ]);
        verifyNever(() => mockLogger.info(any()));
      });

      test('succeeds if no lints are found at all', () async {
        whenRunnerStream(Stream.fromIterable(['line1', 'line2', 'line3']));

        final result = await sut([fakeEntry('a.dart')]);
        expect(result, TaskResult.accepted);
        verify(() => mockLogger.info(any())).called(1);
      });

      test(
        'succeeds if none of the files are staged and option is enabled',
        () async {
          sut = TestableAnalysisTaskBase(
            logger: mockLogger,
            programRunner: mockRunner,
            fileResolver: mockResolver,
            config: const AnalysisConfig(ignoreUnstagedFiles: true),
          );

          whenRunnerStream(Stream.value(json.encode(fullAnalyzeResult)), 1);

          final result = await sut(const []);
          expect(result, TaskResult.accepted);
          verifyInOrder([
            () => mockLogger.info('  error - a.dart:10:11 - a1 1 - A'),
            () => mockLogger.info(
              '  warning - a-a-a.dart:88:99 - a2 - a2-a2 2 - A',
            ),
            () => mockLogger.info('  info - b/b.dart:30:31 - b3 3 - B'),
            () => mockLogger.info('  warning - c/c/c.dart:40:41 - c4 4 - C'),
            () => mockLogger.info('  none - pubspec.yaml:50:51 - d5 5 - D'),
            () => mockLogger.info(
              '5 issue(s) found, but none are in staged files.',
            ),
          ]);
          verifyNever(() => mockLogger.info(any()));
        },
      );

      test(
        'fails if some of the files are staged and option is enabled',
        () async {
          sut = TestableAnalysisTaskBase(
            logger: mockLogger,
            programRunner: mockRunner,
            fileResolver: mockResolver,
            config: const AnalysisConfig(ignoreUnstagedFiles: true),
          );

          whenRunnerStream(Stream.value(json.encode(fullAnalyzeResult)), 1);

          final result = await sut([
            fakeEntry('a.dart'),
            fakeEntry('a-a-a.dart'),
            fakeEntry('b/b.dart'),
            fakeEntry('c/c/d.dart'),
          ]);
          expect(result, TaskResult.rejected);
          verifyInOrder([
            () => mockLogger.info('  error - a.dart:10:11 - a1 1 - A'),
            () => mockLogger.info(
              '  warning - a-a-a.dart:88:99 - a2 - a2-a2 2 - A',
            ),
            () => mockLogger.info('  info - b/b.dart:30:31 - b3 3 - B'),
            () => mockLogger.info('  warning - c/c/c.dart:40:41 - c4 4 - C'),
            () => mockLogger.info('  none - pubspec.yaml:50:51 - d5 5 - D'),
            () => mockLogger.info(
              '5 issue(s) found, 2 of those are in unstaged files.',
            ),
          ]);
          verifyNever(() => mockLogger.info(any()));
        },
      );
    });
  });
}
