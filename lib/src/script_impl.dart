
library unscripted.declaration_script;

import 'dart:io';
import 'dart:mirrors';

import 'package:unscripted/unscripted.dart';
import 'package:unscripted/src/completion/completion.dart';
import 'package:unscripted/src/string_codecs.dart';
import 'package:unscripted/src/usage.dart';
import 'package:unscripted/src/util.dart';

abstract class ScriptImpl implements Script {

  Usage get usage;

  UsageFormatter getUsageFormatter(Usage usage) =>
      new TerminalUsageFormatter(usage);

  execute(
      List<String> arguments,
      {Map<String, String> environment,
       bool isWindows}) {

    CommandInvocation commandInvocation;

    try {
      commandInvocation = usage.validate(arguments);
    } catch (e) {
      // TODO: ArgParser.parse throws FormatException which does not indicate
      // which sub-command was trying to be executed.
      var helpUsage = e is UsageException ? e.usage : usage;
      _handleUsageError(helpUsage, e);
      return;
    }

    if(_checkHelp(commandInvocation)) return;
    if(_checkCompletion(
        commandInvocation,
        environment: environment,
        isWindows: isWindows)) return;
    _handleResults(commandInvocation);

  }

  /// Handles successfully validated [commandInvocation].
  _handleResults(CommandInvocation commandInvocation);

  /// Prints help for [helpUsage].  If [error] is not null, prints the help and
  /// error to [stderr].
  // TODO: Integrate with Loggers.
  _printHelp(Usage helpUsage, [error]) {
    var isError = error != null;
    var sink = stdout;
    if(isError) {
      sink = stderr;
      sink.writeln(error);
      sink.writeln();
    }
    sink.writeln(getUsageFormatter(helpUsage).format());
  }

  _handleUsageError(Usage usage, error) {
    _printHelp(usage, error);
    exitCode = 2;
  }

  bool _checkHelp(CommandInvocation commandInvocation) {
    var path = commandInvocation.helpPath;
    if(path != null) {
      var helpUsage = path
          .fold(usage, (usage, subCommand) =>
              usage.commands[subCommand]);
      _printHelp(helpUsage);
      return true;
    }
    return false;
  }

  bool _checkCompletion(
      CommandInvocation commandInvocation,
      {Map<String, String> environment,
       bool isWindows}) {
    var subCommand = commandInvocation.subCommand;
    if(subCommand != null && subCommand.name == 'completion') {
      complete(usage, subCommand, environment: environment,
          isWindows: isWindows);
      return true;
    }
    return false;
  }
}

abstract class DeclarationScript extends ScriptImpl {

  DeclarationMirror get _declaration;

  MethodMirror get _method;

  DeclarationScript();

  Usage get usage => getUsageFromFunction(_method);

  _handleResults(CommandInvocation commandInvocation) {

    var topInvocation = convertCommandInvocationToInvocation(commandInvocation, _method);

    var topResult = _getTopCommandResult(topInvocation);

    _handleSubCommands(topResult, commandInvocation.subCommand, usage);
  }

  _getTopCommandResult(Invocation invocation);

  _handleSubCommands(InstanceMirror result, CommandInvocation commandInvocation, Usage usage) {

    if(commandInvocation == null) {
      // TODO: Move this to an earlier UsageException instead ?
      if(usage != null && usage.commands.keys.any((commandName) => !['help', 'completion'].contains(commandName))) {
        _handleUsageError(usage, new UsageException(
            usage: usage,
            cause: 'Must specify a sub-command.'));
      }
      return;
    }

    var commandName = commandInvocation.name;
    var commandSymbol = new Symbol(dashesToCamelCase.encode(commandName));
    var classMirror = result.type;
    var methods = classMirror.instanceMembers;
    var commandMethod = methods[commandSymbol];
    var invocation = convertCommandInvocationToInvocation(commandInvocation, commandMethod, memberName: commandSymbol);
    var subResult = result.delegate(invocation);
    Usage subUsage;
    if(commandInvocation.subCommand != null) subUsage = usage.commands[commandInvocation.subCommand.name];
    _handleSubCommands(reflect(subResult), commandInvocation.subCommand, subUsage);
  }

}

class FunctionScript extends DeclarationScript {

  final Function _function;

  MethodMirror get _declaration =>
      (reflect(_function) as ClosureMirror).function;

  MethodMirror get _method => _declaration;

  FunctionScript(this._function) : super();

  _getTopCommandResult(Invocation invocation) => reflect(Function.apply(
      _function,
      invocation.positionalArguments,
      invocation.namedArguments));
}

class ClassScript extends DeclarationScript {

  Type _class;

  ClassMirror get _declaration => reflectClass(_class);

  MethodMirror get _method => getUnnamedConstructor(_declaration);

  ClassScript(this._class) : super();

  _getTopCommandResult(Invocation invocation) => _declaration.newInstance(
      const Symbol(''),
      invocation.positionalArguments,
      invocation.namedArguments);
}