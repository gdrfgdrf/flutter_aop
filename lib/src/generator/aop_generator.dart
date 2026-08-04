import 'dart:async';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

/// Generates proxy classes and aspect registrations.
class AopGenerator extends Generator {
  static const _annotationLibrary = 'package:flutter_aop/src/annotation.dart';
  static const _contextLibrary = 'package:flutter_aop/src/context.dart';

  static const TypeChecker _aopChecker = TypeChecker.fromUrl(
    '$_annotationLibrary#Aop',
  );
  static const TypeChecker _aspectChecker = TypeChecker.fromUrl(
    '$_annotationLibrary#Aspect',
  );
  static const TypeChecker _beforeChecker = TypeChecker.fromUrl(
    '$_annotationLibrary#Before',
  );
  static const TypeChecker _afterChecker = TypeChecker.fromUrl(
    '$_annotationLibrary#After',
  );
  static const TypeChecker _onErrorChecker = TypeChecker.fromUrl(
    '$_annotationLibrary#OnError',
  );
  static const TypeChecker _aroundChecker = TypeChecker.fromUrl(
    '$_annotationLibrary#Around',
  );
  static const TypeChecker _contextChecker = TypeChecker.fromUrl(
    '$_contextLibrary#AopContext',
  );

  @override
  FutureOr<String?> generate(LibraryReader library, BuildStep buildStep) {
    final buffer = StringBuffer();
    final proxies = <_ProxyInfo>[];
    final aspects = <_AspectInfo>[];

    for (final classElement in library.classes) {
      if (_shouldSkipClass(classElement)) continue;

      final annotatedMethods = classElement.methods
          .where(
            (method) =>
                _aopChecker.hasAnnotationOf(method, throwOnUnresolved: false),
          )
          .toList();
      for (final method in annotatedMethods) {
        _validateAopTargetMethod(classElement, method);
      }

      final methods = classElement.methods
          .where((method) => !method.isStatic && !method.isPrivate)
          .toList();
      final hasAnnotatedMethod = annotatedMethods.isNotEmpty;

      if (!hasAnnotatedMethod) continue;

      buffer
        ..writeln(_generateProxyClass(classElement, methods))
        ..writeln();

      if (classElement.typeParameters.isEmpty) {
        proxies.add(
          _ProxyInfo(
            className: classElement.displayName,
            proxyName: '${classElement.displayName}AopProxy',
          ),
        );
      }
    }

    for (final classElement in library.classes) {
      final aspectInfo = _buildAspect(classElement);
      if (aspectInfo != null) {
        aspects.add(aspectInfo);
      }
    }

    if (proxies.isNotEmpty || aspects.isNotEmpty) {
      buffer
        ..writeln(
          _generateInitializationBlock(
            proxies: proxies,
            aspects: aspects,
            buildStep: buildStep,
          ),
        )
        ..writeln();
    }

    final output = buffer.toString().trim();
    if (output.isEmpty) {
      return null;
    }
    return '$output\n';
  }

  bool _shouldSkipClass(ClassElement element) {
    final name = element.name;
    return element.isAbstract ||
        name == null ||
        name.isEmpty ||
        element.isPrivate;
  }

  void _validateAopTargetMethod(ClassElement owner, MethodElement method) {
    final name = method.name ?? method.displayName;
    if (method.isPrivate) {
      throw InvalidGenerationSourceError(
        'Invalid @Aop target on ${owner.displayName}.$name: private methods '
        'cannot be proxied. Fix: make the method public or remove @Aop.',
        element: method,
      );
    }
    if (method.isStatic) {
      throw InvalidGenerationSourceError(
        'Invalid @Aop target on ${owner.displayName}.$name: static methods '
        'cannot be proxied. Fix: move logic to an instance method or remove @Aop.',
        element: method,
      );
    }
    if (method.isOperator) {
      throw InvalidGenerationSourceError(
        'Invalid @Aop target on ${owner.displayName}.$name: operator methods '
        'are not supported. Fix: wrap the behavior in a public instance method '
        'and annotate that method instead.',
        element: method,
      );
    }
  }

  String _generateProxyClass(
    ClassElement element,
    List<MethodElement> methods,
  ) {
    final buffer = StringBuffer();
    final className = element.displayName;
    final typeParams = _typeParameters(element);
    final typeArgs = _typeArguments(element);
    final proxyName = '${className}AopProxy';

    buffer
      ..writeln('class $proxyName$typeParams implements $className$typeArgs {')
      ..writeln('  $proxyName(this._target, {AopHooks? hooks})')
      ..writeln('      : _localHooks = hooks;')
      ..writeln()
      ..writeln('  final $className$typeArgs _target;')
      ..writeln('  final AopHooks? _localHooks;');

    final accessors = <PropertyAccessorElement>[
      ...element.getters,
      ...element.setters,
    ].where((accessor) => !accessor.isStatic && !accessor.isPrivate);

    for (final accessor in accessors) {
      buffer
        ..writeln()
        ..writeln(_generateAccessor(accessor));
    }

    for (final method in methods) {
      buffer
        ..writeln()
        ..writeln(_generateMethod(element, method));
    }

    buffer.writeln('}');
    return buffer.toString();
  }

  String _generateAccessor(PropertyAccessorElement accessor) {
    final returnType = accessor.returnType.getDisplayString();
    final fieldName = accessor.displayName;
    if (accessor is GetterElement) {
      return [
        '  @override',
        '  $returnType get $fieldName => _target.$fieldName;',
      ].join('\n');
    }

    final setter = accessor as SetterElement;
    final parameterType = setter.formalParameters.first.type.getDisplayString();
    return [
      '  @override',
      '  set $fieldName($parameterType value) => _target.$fieldName = value;',
    ].join('\n');
  }

  String _generateMethod(ClassElement element, MethodElement method) {
    final annotationValue = _aopChecker.firstAnnotationOf(
      method,
      throwOnUnresolved: false,
    );
    final annotationLiteral = _annotationLiteral(annotationValue);
    final hasAnnotation = annotationValue != null;
    final returnType = method.returnType.getDisplayString();
    final methodName = method.name ?? method.displayName;
    final descriptionName = method.displayName;
    final methodTypeParameters = _methodTypeParameters(method);
    final methodTypeArguments = _methodTypeArguments(method);
    final parameters = method.formalParameters;
    final signature = _parameterSignature(parameters);
    final callArguments = _methodArguments(parameters);
    final positionalArgsList = _positionalArgumentsLiteral(parameters);
    final namedArgsMap = _namedArgumentsLiteral(parameters);
    final description = '$returnType $descriptionName($signature)'
        .trim()
        .replaceAll('\n', ' ');

    final buffer = StringBuffer()
      ..writeln('  @override')
      ..write('  $returnType $methodName$methodTypeParameters($signature)');

    if (!hasAnnotation) {
      buffer.writeln(
        ' => _target.$methodName$methodTypeArguments($callArguments);',
      );
      return buffer.toString();
    }

    final isAsync = _returnsFuture(method.returnType);
    final dispatcher = isAsync ? 'runAsyncWithAop' : 'runSyncWithAop';
    final typeArg = _methodResultType(method.returnType);
    final invocation =
        '_target.$methodName$methodTypeArguments($callArguments)';

    buffer
      ..writeln(' {')
      ..writeln('    const annotation = $annotationLiteral;')
      ..writeln('    final context = AopContext(')
      ..writeln("      target: _target,")
      ..writeln("      className: '${element.displayName}',")
      ..writeln("      methodName: '$methodName',")
      ..writeln('      annotation: annotation,')
      ..writeln('      positionalArguments: $positionalArgsList,')
      ..writeln('      namedArguments: $namedArgsMap,')
      ..writeln('    );');

    if (isAsync) {
      buffer
        ..writeln('    return $dispatcher<$typeArg>(')
        ..writeln('      context: context,')
        ..writeln('      localHooks: _localHooks,')
        ..writeln('      invoke: () => $invocation,')
        ..writeln('    );');
    } else {
      final returnKeyword = returnType == 'void' ? '' : 'return ';
      buffer
        ..writeln('    $returnKeyword$dispatcher<$typeArg>(')
        ..writeln('      context: context,')
        ..writeln('      localHooks: _localHooks,')
        ..writeln('      invoke: () => $invocation,')
        ..writeln('    );');
    }
    buffer
      ..writeln('  }')
      ..writeln('  // Proxy for: $description');

    return buffer.toString();
  }

  _AspectInfo? _buildAspect(ClassElement element) {
    if (!_aspectChecker.hasAnnotationOf(element, throwOnUnresolved: false)) {
      return null;
    }
    if (element.isAbstract) {
      throw InvalidGenerationSourceError(
        'Invalid @Aspect target on ${element.displayName}: abstract classes '
        'cannot be instantiated for advice registration. Fix: remove the '
        'abstract modifier or move advices to a concrete class.',
        element: element,
      );
    }

    final annotation = _aspectChecker.firstAnnotationOf(
      element,
      throwOnUnresolved: false,
    );
    final defaultTag = annotation?.getField('tag')?.toStringValue();
    final order = annotation?.getField('order')?.toIntValue() ?? 0;

    final constructor = element.unnamedConstructor;
    if (constructor != null) {
      final hasRequiredParam = constructor.formalParameters.any(
        (param) => !param.isOptional && !param.hasDefaultValue,
      );
      if (hasRequiredParam) {
        throw InvalidGenerationSourceError(
          'Invalid @Aspect constructor on ${element.displayName}: the unnamed '
          'constructor has required parameters, so the generator cannot create '
          'an instance. Fix: provide an unnamed constructor without required '
          'parameters.',
          element: element,
        );
      }
    }

    final instantiation = constructor == null
        ? '${element.displayName}()'
        : constructor.isConst
        ? 'const ${element.displayName}()'
        : '${element.displayName}()';

    final advices = <_AdviceInfo>[];
    for (final method in element.methods.where(
      (method) => !method.isStatic && !method.isPrivate,
    )) {
      void addAdvice(TypeChecker checker, _AdviceType type) {
        final data = checker.firstAnnotationOf(
          method,
          throwOnUnresolved: false,
        );
        if (data == null) return;

        // Validate signature based on advice type
        if (type == _AdviceType.around) {
          _validateAroundAdviceSignature(element, method);
        } else {
          _validateAdviceSignature(element, method);
        }

        final explicitTag = data.getField('tag')?.toStringValue();
        final effectiveTag = explicitTag ?? defaultTag;
        final pointcut = _resolveAdvicePointcut(
          aspect: element,
          method: method,
          annotation: data,
          effectiveTag: effectiveTag,
        );

        advices.add(
          _AdviceInfo(
            methodName: method.name ?? method.displayName,
            type: type,
            tag: effectiveTag,
            pointcut: pointcut,
          ),
        );
      }

      addAdvice(_beforeChecker, _AdviceType.before);
      addAdvice(_afterChecker, _AdviceType.after);
      addAdvice(_onErrorChecker, _AdviceType.onError);
      addAdvice(_aroundChecker, _AdviceType.around);
    }

    if (advices.isEmpty) {
      return null;
    }

    return _AspectInfo(
      className: element.displayName,
      instantiation: instantiation,
      advices: advices,
      order: order,
    );
  }

  _PointcutInfo? _resolveAdvicePointcut({
    required ClassElement aspect,
    required MethodElement method,
    required DartObject annotation,
    required String? effectiveTag,
  }) {
    final pointcutData = annotation.getField('pointcut');
    if (pointcutData == null || pointcutData.isNull) {
      return null;
    }

    final classPattern = pointcutData.getField('classPattern')?.toStringValue();
    final methodPattern = pointcutData
        .getField('methodPattern')
        ?.toStringValue();
    final pointcutTag = pointcutData.getField('tag')?.toStringValue();

    if (pointcutTag != null &&
        effectiveTag != null &&
        pointcutTag != effectiveTag) {
      throw InvalidGenerationSourceError(
        'Invalid advice configuration on ${aspect.displayName}.'
        '${method.displayName}: advice tag ($effectiveTag) conflicts with '
        'pointcut tag ($pointcutTag). Fix: make both tags match or remove one.',
        element: method,
      );
    }

    return _PointcutInfo(
      classPattern: classPattern,
      methodPattern: methodPattern,
      tag: pointcutTag ?? effectiveTag,
    );
  }

  void _validateAdviceSignature(ClassElement aspect, MethodElement method) {
    if (method.formalParameters.length != 1) {
      throw InvalidGenerationSourceError(
        'Invalid advice signature on ${aspect.displayName}.'
        '${method.displayName}: advice methods must accept exactly one '
        'AopContext parameter. Fix: declare the method as '
        '`void method(AopContext context)` (or FutureOr for @Around).',
        element: method,
      );
    }

    final parameter = method.formalParameters.first;
    if (!_contextChecker.isAssignableFromType(parameter.type)) {
      throw InvalidGenerationSourceError(
        'Invalid advice signature on ${aspect.displayName}.'
        '${method.displayName}: the single parameter must be AopContext. '
        'Fix: change the parameter type to AopContext.',
        element: method,
      );
    }
  }

  void _validateAroundAdviceSignature(
    ClassElement aspect,
    MethodElement method,
  ) {
    // First validate the parameter
    _validateAdviceSignature(aspect, method);

    // Around advice must return a value (not void)
    // because it needs to return the result of proceed()
    final returnType = method.returnType;
    if (returnType is VoidType) {
      throw InvalidGenerationSourceError(
        'Invalid @Around signature on ${aspect.displayName}.'
        '${method.displayName}: around advice must return a value so '
        'proceed() can flow through. Fix: use FutureOr<dynamic> or a concrete '
        'return type instead of void.',
        element: method,
      );
    }
  }

  String _generateInitializationBlock({
    required List<_ProxyInfo> proxies,
    required List<_AspectInfo> aspects,
    required BuildStep buildStep,
  }) {
    if (proxies.isEmpty && aspects.isEmpty) {
      return '';
    }
    final identifier = _sanitizeIdentifier(buildStep.inputId.path);
    final initializedField = '_\$flutterAopInitialized_$identifier';
    final initFunction = '_\$flutterAopEnsureInitialized_$identifier';
    final bootstrapField = '_\$flutterAopBootstrap_$identifier';
    final publicBootstrap = 'flutterAopBootstrap$identifier';
    final buffer = StringBuffer()
      ..writeln('bool $initializedField = false;')
      ..writeln('bool $initFunction() {')
      ..writeln('  if ($initializedField) {')
      ..writeln('    return true;')
      ..writeln('  }')
      ..writeln('  $initializedField = true;');

    if (proxies.isNotEmpty) {
      buffer.writeln('  final proxyRegistry = AopProxyRegistry.instance;');
      for (final proxy in proxies) {
        buffer.writeln(
          '  proxyRegistry.register<${proxy.className}>(('
          '${proxy.className} target, {AopHooks? hooks}) => '
          '${proxy.proxyName}(target, hooks: hooks),'
          ');',
        );
      }
    }

    if (aspects.isNotEmpty) {
      buffer.writeln('  final hookRegistry = AopRegistry.instance;');
      for (var i = 0; i < aspects.length; i++) {
        final aspect = aspects[i];
        buffer.writeln('  final aspect$i = ${aspect.instantiation};');
        for (final advice in aspect.advices) {
          final hookField = _adviceField(advice.type);
          final pointcutLiteral = advice.pointcut?.toLiteral();
          if (pointcutLiteral != null) {
            buffer.writeln('  hookRegistry.registerWithPointcut(');
            buffer.writeln(
              '    AopHooks($hookField: aspect$i.${advice.methodName}),',
            );
            buffer.writeln('    pointcut: $pointcutLiteral,');
            buffer.writeln('    order: ${aspect.order},');
            buffer.writeln('  );');
            continue;
          }
          final tagLiteral = advice.tag == null
              ? ''
              : 'tag: ${literalString(advice.tag!)}';
          buffer.writeln('  hookRegistry.register(');
          buffer.writeln(
            '    AopHooks($hookField: aspect$i.${advice.methodName}),',
          );
          if (tagLiteral.isNotEmpty) {
            buffer.writeln('    $tagLiteral,');
          }
          buffer.writeln('    order: ${aspect.order},');
          buffer.writeln('  );');
        }
      }
    }

    buffer
      ..writeln('  return true;')
      ..writeln('}')
      ..writeln('@pragma(\'vm:entry-point\', \'get\')')
      ..writeln(
        'final bool $bootstrapField = '
        'AopBootstrapper.instance.register($initFunction);',
      )
      ..writeln('void $publicBootstrap() {')
      ..writeln('  // ignore: unused_local_variable')
      ..writeln('  final bool _ = $bootstrapField;')
      ..writeln('}');

    return buffer.toString();
  }

  String _adviceField(_AdviceType type) {
    switch (type) {
      case _AdviceType.before:
        return 'before';
      case _AdviceType.after:
        return 'after';
      case _AdviceType.onError:
        return 'onError';
      case _AdviceType.around:
        return 'around';
    }
  }

  bool _returnsFuture(DartType type) {
    return type.isDartAsyncFuture || type.isDartAsyncFutureOr;
  }

  String _methodResultType(DartType type) {
    if (type is VoidType) return 'void';
    if (type.isDartAsyncFuture || type.isDartAsyncFutureOr) {
      if (type is ParameterizedType && type.typeArguments.isNotEmpty) {
        return type.typeArguments.first.getDisplayString();
      }
      return 'dynamic';
    }
    if (type is TypeParameterType) {
      return type.getDisplayString();
    }
    return type.getDisplayString();
  }

  String _typeParameters(ClassElement element) {
    return _typeParametersForElements(element.typeParameters);
  }

  String _typeArguments(ClassElement element) {
    return _typeArgumentsForElements(element.typeParameters);
  }

  String _methodTypeParameters(MethodElement method) {
    return _typeParametersForElements(method.typeParameters);
  }

  String _methodTypeArguments(MethodElement method) {
    return _typeArgumentsForElements(method.typeParameters);
  }

  String _typeParametersForElements(List<TypeParameterElement> parameters) {
    if (parameters.isEmpty) return '';
    final params = parameters
        .map((param) {
          final bound = param.bound == null
              ? ''
              : ' extends ${param.bound!.getDisplayString()}';
          final name = param.displayName;
          return '$name$bound';
        })
        .join(', ');
    return '<$params>';
  }

  String _typeArgumentsForElements(List<TypeParameterElement> parameters) {
    if (parameters.isEmpty) return '';
    final args = parameters.map((param) => param.displayName).join(', ');
    return '<$args>';
  }

  String _parameterSignature(List<FormalParameterElement> parameters) {
    final required = parameters
        .where((param) => param.isRequiredPositional)
        .map(_formatParameter)
        .toList();
    final optionalPositional = parameters
        .where((param) => param.isOptionalPositional)
        .map(_formatParameter)
        .toList();
    final named = parameters
        .where((param) => param.isNamed)
        .map(_formatParameter)
        .toList();

    final chunks = <String>[];
    if (required.isNotEmpty) {
      chunks.add(required.join(', '));
    }
    if (optionalPositional.isNotEmpty) {
      chunks.add('[${optionalPositional.join(', ')}]');
    }
    if (named.isNotEmpty) {
      chunks.add('{${named.join(', ')}}');
    }
    return chunks.join(', ');
  }

  String _formatParameter(FormalParameterElement parameter) {
    final modifier = StringBuffer();
    if (parameter.isRequiredNamed) {
      modifier.write('required ');
    }
    if (parameter.isCovariant) {
      modifier.write('covariant ');
    }
    final type = parameter.type.getDisplayString();
    final defaultValue = parameter.hasDefaultValue
        ? ' = ${parameter.defaultValueCode}'
        : '';
    return '$modifier$type ${parameter.displayName}$defaultValue';
  }

  String _methodArguments(List<FormalParameterElement> parameters) {
    final chunks = <String>[];
    for (final param in parameters) {
      if (param.isNamed) {
        final name = param.name ?? param.displayName;
        chunks.add('$name: ${param.displayName}');
      } else {
        chunks.add(param.displayName);
      }
    }
    return chunks.join(', ');
  }

  String _positionalArgumentsLiteral(List<FormalParameterElement> parameters) {
    final positional = parameters.where((param) => param.isPositional);
    if (positional.isEmpty) {
      return 'LinkedHashMap()';
    }
    final entries = positional.map((param) {
      final name = param.name ?? param.displayName;
      final value = param.displayName;
      return "..['$name'] = $value";
    }).join();
    return 'LinkedHashMap()$entries';
  }

  String _namedArgumentsLiteral(List<FormalParameterElement> parameters) {
    final named = parameters.where((param) => param.isNamed).toList();
    if (named.isEmpty) {
      return 'const <String, dynamic>{}';
    }

    final entries = named
        .map((param) {
          final name = param.name ?? param.displayName;
          return "'$name': ${param.displayName}";
        })
        .join(', ');
    return '<String, dynamic>{$entries}';
  }

  String _annotationLiteral(DartObject? annotation) {
    if (annotation == null) {
      return 'Aop()';
    }
    final before = annotation.getField('before')?.toBoolValue() ?? true;
    final after = annotation.getField('after')?.toBoolValue() ?? true;
    final onError = annotation.getField('onError')?.toBoolValue() ?? true;
    final tag = annotation.getField('tag')?.toStringValue();
    final description = annotation.getField('description')?.toStringValue();

    final buffer = StringBuffer('Aop(')
      ..write('before: $before, ')
      ..write('after: $after, ')
      ..write('onError: $onError');

    if (tag != null) {
      buffer.write(", tag: ${literalString(tag)}");
    }
    if (description != null) {
      buffer.write(", description: ${literalString(description)}");
    }
    buffer.write(')');
    return buffer.toString();
  }
}

String literalString(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n');
  return "'$escaped'";
}

String _sanitizeIdentifier(String input) {
  final buffer = StringBuffer();
  for (final codeUnit in input.codeUnits) {
    final char = String.fromCharCode(codeUnit);
    if (RegExp(r'[A-Za-z0-9_]').hasMatch(char)) {
      buffer.write(char);
    } else {
      buffer.write('_');
    }
  }
  return buffer.toString();
}

class _ProxyInfo {
  const _ProxyInfo({required this.className, required this.proxyName});

  final String className;
  final String proxyName;
}

class _AspectInfo {
  const _AspectInfo({
    required this.className,
    required this.instantiation,
    required this.advices,
    required this.order,
  });

  final String className;
  final String instantiation;
  final List<_AdviceInfo> advices;
  final int order;
}

class _AdviceInfo {
  const _AdviceInfo({
    required this.methodName,
    required this.type,
    required this.tag,
    required this.pointcut,
  });

  final String methodName;
  final _AdviceType type;
  final String? tag;
  final _PointcutInfo? pointcut;
}

class _PointcutInfo {
  const _PointcutInfo({this.classPattern, this.methodPattern, this.tag});

  final String? classPattern;
  final String? methodPattern;
  final String? tag;

  String toLiteral() {
    final parts = <String>[];
    if (classPattern != null) {
      parts.add('classPattern: ${literalString(classPattern!)}');
    }
    if (methodPattern != null) {
      parts.add('methodPattern: ${literalString(methodPattern!)}');
    }
    if (tag != null) {
      parts.add('tag: ${literalString(tag!)}');
    }
    if (parts.isEmpty) {
      return 'const Pointcut()';
    }
    return 'const Pointcut(${parts.join(', ')})';
  }
}

enum _AdviceType { before, after, onError, around }
