/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * A small POSIX-flavoured shell that runs inside the application sandbox.
 * It owns no I/O: the UI feeds whole lines in, rendered output comes back as
 * plain text lines. Filesystem access goes through ShellFs so the same engine
 * can be unit-tested on Node and plugged into the HarmonyOS sandbox.
 */

import { FileEntry } from '../fs/FileEntry';
import { humanSize, modeString, formatDate, naturalCompare } from '../fs/Format';
import { normalizePath, resolvePath, joinPath, baseName, parentPath } from '../fs/PathUtil';

export interface ShellFs {
  /** Absolute virtual path, '/' is the sandbox root. */
  cwd: string;
  list(path: string): Array<FileEntry>;
  stat(path: string): FileEntry | null;
  readText(path: string): string;
  writeText(path: string, text: string, append: boolean): void;
  mkdir(path: string): void;
  remove(path: string, dir: boolean): void;
  rename(from: string, to: string): void;
  copy(from: string, to: string): void;
  readlink(path: string): string;
}

export class ShellOutput {
  lines: Array<string>;
  code: number;
  clear: boolean;
  exit: boolean;

  constructor(lines: Array<string>, code: number) {
    this.lines = lines;
    this.code = code;
    this.clear = false;
    this.exit = false;
  }
}

export class Completion {
  line: string;
  caret: number;
  candidates: Array<string>;

  constructor(line: string, caret: number, candidates: Array<string>) {
    this.line = line;
    this.caret = caret;
    this.candidates = candidates;
  }
}

class Word {
  text: string;
  kind: number; // 0 word, 1 pipe, 2 semicolon, 3 '>', 4 '>>', 5 '<'

  constructor(text: string, kind: number) {
    this.text = text;
    this.kind = kind;
  }
}

class Pipeline {
  segments: Array<Array<string>>;
  inFile: string;
  outFile: string;
  append: boolean;

  constructor() {
    this.segments = [];
    this.inFile = '';
    this.outFile = '';
    this.append = false;
  }
}

class ParseError {
  message: string;

  constructor(message: string) {
    this.message = message;
  }
}

const KIND_WORD: number = 0;
const KIND_PIPE: number = 1;
const KIND_SEMI: number = 2;
const KIND_OUT: number = 3;
const KIND_APPEND: number = 4;
const KIND_IN: number = 5;

/** Escapes a quoted '$' so variable expansion cannot see it. */
const DOLLAR: string = '\u0001';

const COMMANDS: Array<string> = [
  'cat', 'cd', 'clear', 'cp', 'date', 'df', 'du', 'echo', 'env', 'exit',
  'grep', 'head', 'help', 'history', 'hostname', 'id', 'ls', 'mkdir', 'mv',
  'pwd', 'rm', 'rmdir', 'sleep', 'sort', 'stat', 'tail', 'tee', 'touch',
  'true', 'false', 'uname', 'wc', 'whoami'
];

function rtrimSlash(text: string): string {
  return text.length > 1 && text.endsWith('/') ? text.substring(0, text.length - 1) : text;
}

export class Shell {
  private fs: ShellFs;
  private user: string;
  private host: string;
  private env: Map<string, string>;
  private lastCode: number;
  history: Array<string>;
  private historyCursor: number;
  private pending: string;
  private exited: boolean;

  constructor(fs: ShellFs, user: string, host: string) {
    this.fs = fs;
    this.user = user;
    this.host = host;
    this.env = new Map<string, string>();
    this.env.set('HOME', '/');
    this.env.set('USER', user);
    this.env.set('HOSTNAME', host);
    this.env.set('SHELL', '/bin/ohsh');
    this.env.set('PWD', fs.cwd);
    this.lastCode = 0;
    this.history = [];
    this.historyCursor = 0;
    this.pending = '';
    this.exited = false;
  }

  prompt(): string {
    const home: string = this.env.get('HOME') ?? '/';
    const cwd: string = this.fs.cwd;
    const shown: string = cwd === home ? '~' : cwd;
    return `${this.user}@${this.host}:${shown}$ `;
  }

  isExited(): boolean {
    return this.exited;
  }

  /** Previous/next entry for Up-arrow recall. Returns null at the ends. */
  recall(direction: number): string | null {
    if (this.history.length === 0) {
      return null;
    }
    if (direction < 0) {
      if (this.historyCursor > 0) {
        this.historyCursor--;
      }
      return this.history[this.historyCursor];
    }
    if (this.historyCursor < this.history.length - 1) {
      this.historyCursor++;
      return this.history[this.historyCursor];
    }
    this.historyCursor = this.history.length;
    return this.pending;
  }

  setPending(text: string): void {
    this.pending = text;
    this.historyCursor = this.history.length;
  }

  execute(line: string): ShellOutput {
    const trimmed: string = line.trim();
    if (trimmed.length === 0) {
      return new ShellOutput([], 0);
    }
    if (this.history.length === 0 || this.history[this.history.length - 1] !== trimmed) {
      this.history.push(trimmed);
      if (this.history.length > 500) {
        this.history.shift();
      }
    }
    this.historyCursor = this.history.length;
    this.pending = '';

    const pipelines: Array<Pipeline> | ParseError = this.parse(trimmed);
    if (pipelines instanceof ParseError) {
      this.lastCode = 2;
      return new ShellOutput([`ohsh: ${pipelines.message}`], 2);
    }

    const lines: Array<string> = [];
    let code: number = 0;
    for (let i = 0; i < pipelines.length; i++) {
      const result: ShellOutput = this.runPipeline(pipelines[i]);
      lines.push(...result.lines);
      code = result.code;
      this.lastCode = code;
      if (result.clear) {
        const cleared: ShellOutput = new ShellOutput([], 0);
        cleared.clear = true;
        return cleared;
      }
      if (result.exit) {
        this.exited = true;
        const cut: ShellOutput = new ShellOutput(lines, code);
        cut.exit = true;
        return cut;
      }
    }
    this.lastCode = code;
    return new ShellOutput(lines, code);
  }

  // ---------------------------------------------------------------- parsing

  private tokenize(line: string): Array<Word> | ParseError {
    const words: Array<Word> = [];
    let buffer: string = '';
    let quoted: boolean = false;
    let quote: string = '';
    let i: number = 0;
    const flush = (): void => {
      if (buffer.length > 0 || quoted) {
        words.push(new Word(buffer, KIND_WORD));
        buffer = '';
        quoted = false;
      }
    };
    while (i < line.length) {
      const ch: string = line.charAt(i);
      if (quote === '\'') {
        if (ch === '\'') {
          quote = '';
        } else {
          buffer += ch === '$' ? DOLLAR : ch;
        }
        i++;
        continue;
      }
      if (quote === '"') {
        if (ch === '"') {
          quote = '';
        } else if (ch === '\\' && i + 1 < line.length) {
          const next: string = line.charAt(i + 1);
          if (next === '"' || next === '\\' || next === '$' || next === '`') {
            buffer += next;
            i++;
          } else {
            buffer += ch;
          }
        } else {
          buffer += ch;
        }
        i++;
        continue;
      }
      if (ch === '\\' && i + 1 < line.length) {
        const escaped: string = line.charAt(i + 1);
        buffer += escaped === '$' ? DOLLAR : escaped;
        quoted = true;
        i += 2;
        continue;
      }
      if (ch === '\'') {
        quote = '\'';
        quoted = true;
        i++;
        continue;
      }
      if (ch === '"') {
        quote = '"';
        quoted = true;
        i++;
        continue;
      }
      if (ch === ' ' || ch === '\t') {
        flush();
        i++;
        continue;
      }
      if (ch === '|') {
        flush();
        words.push(new Word('|', KIND_PIPE));
        i++;
        continue;
      }
      if (ch === ';') {
        flush();
        words.push(new Word(';', KIND_SEMI));
        i++;
        continue;
      }
      if (ch === '>') {
        flush();
        if (line.charAt(i + 1) === '>') {
          words.push(new Word('>>', KIND_APPEND));
          i += 2;
        } else {
          words.push(new Word('>', KIND_OUT));
          i++;
        }
        continue;
      }
      if (ch === '<') {
        flush();
        words.push(new Word('<', KIND_IN));
        i++;
        continue;
      }
      buffer += ch;
      i++;
    }
    if (quote !== '') {
      return new ParseError('unexpected EOF while looking for matching quote');
    }
    flush();
    return words;
  }

  private parse(line: string): Array<Pipeline> | ParseError {
    const words: Array<Word> | ParseError = this.tokenize(line);
    if (words instanceof ParseError) {
      return words;
    }
    const pipelines: Array<Pipeline> = [];
    let pipeline: Pipeline = new Pipeline();
    let segment: Array<string> = [];
    const endSegment = (): void => {
      if (segment.length > 0) {
        pipeline.segments.push(segment);
        segment = [];
      }
    };
    const endPipeline = (): void => {
      endSegment();
      if (pipeline.segments.length > 0) {
        pipelines.push(pipeline);
      }
      pipeline = new Pipeline();
    };
    for (let i = 0; i < words.length; i++) {
      const word: Word = words[i];
      if (word.kind === KIND_WORD) {
        segment.push(word.text);
      } else if (word.kind === KIND_PIPE) {
        endSegment();
        if (pipeline.segments.length === 0) {
          return new ParseError('syntax error near unexpected token `|\'');
        }
      } else if (word.kind === KIND_SEMI) {
        endPipeline();
      } else {
        const isInput: boolean = word.kind === KIND_IN;
        if (i + 1 >= words.length || words[i + 1].kind !== KIND_WORD) {
          return new ParseError(isInput ? 'syntax error near `<`'
                                        : 'syntax error near `>`');
        }
        const target: string = this.expand(words[i + 1].text);
        if (isInput) {
          pipeline.inFile = target;
        } else {
          pipeline.outFile = target;
          pipeline.append = word.kind === KIND_APPEND;
        }
        i++;
      }
    }
    endPipeline();
    if (words.length > 0 && words[words.length - 1].kind === KIND_PIPE) {
      return new ParseError('syntax error near unexpected token `|\'');
    }
    return pipelines;
  }

  // -------------------------------------------------------------- expansion

  private lookup(name: string): string {
    if (name === '?') {
      return `${this.lastCode}`;
    }
    const value: string | undefined = this.env.get(name);
    return value === undefined ? '' : value;
  }

  private expand(raw: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < raw.length) {
      const ch: string = raw.charAt(i);
      if (ch === DOLLAR) {
        out += '$';
        i++;
        continue;
      }
      if (ch === '\'') {
        const end: number = raw.indexOf('\'', i + 1);
        if (end < 0) {
          out += raw.substring(i + 1);
          break;
        }
        out += raw.substring(i + 1, end);
        i = end + 1;
        continue;
      }
      if (ch !== '$') {
        out += ch;
        i++;
        continue;
      }
      if (raw.charAt(i + 1) === '{') {
        const end: number = raw.indexOf('}', i + 2);
        if (end < 0) {
          out += ch;
          i++;
          continue;
        }
        out += this.lookup(raw.substring(i + 2, end));
        i = end + 1;
        continue;
      }
      let j: number = i + 1;
      if (j < raw.length && raw.charAt(j) === '?') {
        out += this.lookup('?');
        i = j + 1;
        continue;
      }
      while (j < raw.length) {
        const c: string = raw.charAt(j);
        const alpha: boolean = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_';
        const digit: boolean = c >= '0' && c <= '9';
        if (!alpha && !digit) {
          break;
        }
        j++;
      }
      if (j === i + 1) {
        out += ch;
        i++;
      } else {
        out += this.lookup(raw.substring(i + 1, j));
        i = j;
      }
    }
    if (out.startsWith('~')) {
      if (out === '~' || out.startsWith('~/')) {
        out = (this.env.get('HOME') ?? '/') + out.substring(1);
      }
    }
    return out;
  }

  private absolute(path: string): string {
    return resolvePath(this.fs.cwd, path);
  }

  private glob(word: string): Array<string> {
    if (word.indexOf('*') < 0 && word.indexOf('?') < 0) {
      return [word];
    }
    const resolved: string = this.absolute(word);
    const dir: string = parentPath(resolved);
    const pattern: string = baseName(resolved);
    let entries: Array<FileEntry> = [];
    try {
      entries = this.fs.list(dir);
    } catch (e) {
      return [word];
    }
    if (pattern === '' || (pattern.indexOf('*') < 0 && pattern.indexOf('?') < 0)) {
      return [word];
    }
    const regex: RegExp = new RegExp('^' + pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&')
      .replace(/\*/g, '[^/]*').replace(/\?/g, '[^/]') + '$');
    const matches: Array<string> = [];
    for (let i = 0; i < entries.length; i++) {
      const name: string = entries[i].name;
      if (name.startsWith('.') && !pattern.startsWith('.')) {
        continue;
      }
      if (regex.test(name)) {
        matches.push(name);
      }
    }
    matches.sort(naturalCompare);
    if (matches.length === 0) {
      return [word];
    }
    if (word.startsWith('/') || word.startsWith('~')) {
      const prefix: string = dir === '/' ? '/' : dir + '/';
      const absolute: Array<string> = [];
      for (let i = 0; i < matches.length; i++) {
        absolute.push(prefix + matches[i]);
      }
      return absolute;
    }
    return matches;
  }

  // -------------------------------------------------------------- execution

  private splitCommands(tokens: Array<string>): Array<Array<string>> {
    const argv: Array<string> = [];
    for (let i = 0; i < tokens.length; i++) {
      const expanded: string = this.expand(tokens[i]);
      const globbed: Array<string> = this.glob(expanded);
      for (let j = 0; j < globbed.length; j++) {
        argv.push(globbed[j]);
      }
    }
    return [argv];
  }

  private runPipeline(pipeline: Pipeline): ShellOutput {
    let stdin: Array<string> = [];
    if (pipeline.inFile.length > 0) {
      try {
        stdin = this.readLines(this.fs.readText(this.absolute(pipeline.inFile)));
      } catch (e) {
        return new ShellOutput([`ohsh: ${pipeline.inFile}: cannot open input`], 1);
      }
    }
    let output: ShellOutput = new ShellOutput([], 0);
    for (let i = 0; i < pipeline.segments.length; i++) {
      const argv: Array<string> = this.splitCommands(pipeline.segments[i])[0];
      if (argv.length === 0) {
        continue;
      }
      output = this.runCommand(argv, stdin);
      if (output.exit) {
        return output;
      }
      stdin = output.lines;
    }
    if (pipeline.outFile.length > 0) {
      const target: string = this.absolute(pipeline.outFile);
      const text: string = output.lines.length > 0 ? output.lines.join('\n') + '\n' : '';
      try {
        this.fs.writeText(target, text, pipeline.append);
      } catch (e) {
        return new ShellOutput([`ohsh: ${pipeline.outFile}: cannot write`], 1);
      }
      return new ShellOutput([], output.code);
    }
    return output;
  }

  private readLines(text: string): Array<string> {
    if (text.length === 0) {
      return [];
    }
    const lines: Array<string> = text.split('\n');
    if (lines.length > 0 && lines[lines.length - 1] === '') {
      lines.pop();
    }
    return lines;
  }

  private runCommand(argv: Array<string>, stdin: Array<string>): ShellOutput {
    const name: string = argv[0];
    const args: Array<string> = argv.slice(1);
    try {
      if (name === 'exit') {
        const result: ShellOutput = new ShellOutput([], 0);
        result.exit = true;
        return result;
      }
      return this.dispatch(name, args, stdin);
    } catch (e) {
      const message: string = e instanceof Error ? e.message : `${e}`;
      return new ShellOutput([`ohsh: ${name}: ${message}`], 1);
    }
  }

  private dispatch(name: string, args: Array<string>, stdin: Array<string>): ShellOutput {
    if (name === 'ls') {
      return this.builtinLs(args);
    }
    if (name === 'cd') {
      return this.builtinCd(args);
    }
    if (name === 'pwd') {
      return new ShellOutput([this.fs.cwd], 0);
    }
    if (name === 'cat') {
      return this.builtinCat(args, stdin);
    }
    if (name === 'echo') {
      return this.builtinEcho(args);
    }
    if (name === 'mkdir') {
      return this.builtinMkdir(args);
    }
    if (name === 'rmdir') {
      return this.builtinRm(args, true);
    }
    if (name === 'rm') {
      return this.builtinRm(args, false);
    }
    if (name === 'mv') {
      return this.builtinMv(args);
    }
    if (name === 'cp') {
      return this.builtinCp(args);
    }
    if (name === 'touch') {
      return this.builtinTouch(args);
    }
    if (name === 'head' || name === 'tail') {
      return this.builtinHeadTail(name, args, stdin);
    }
    if (name === 'wc') {
      return this.builtinWc(args, stdin);
    }
    if (name === 'grep') {
      return this.builtinGrep(args, stdin);
    }
    if (name === 'sort') {
      return this.builtinSort(args, stdin);
    }
    if (name === 'stat') {
      return this.builtinStat(args);
    }
    if (name === 'du') {
      return this.builtinDu(args);
    }
    if (name === 'df') {
      return this.builtinDf();
    }
    if (name === 'date') {
      return new ShellOutput([new Date().toString()], 0);
    }
    if (name === 'uname') {
      return new ShellOutput(['OpenHarmony ohos 6.1 aarch64'], 0);
    }
    if (name === 'hostname') {
      return new ShellOutput([this.host], 0);
    }
    if (name === 'whoami') {
      return new ShellOutput([this.user], 0);
    }
    if (name === 'id') {
      return new ShellOutput([`uid=2000(${this.user}) gid=2000(${this.user})`], 0);
    }
    if (name === 'env') {
      const lines: Array<string> = [];
      this.env.forEach((value: string, key: string): void => {
        lines.push(`${key}=${value}`);
      });
      lines.sort(naturalCompare);
      return new ShellOutput(lines, 0);
    }
    if (name === 'history') {
      const lines: Array<string> = [];
      for (let i = 0; i < this.history.length; i++) {
        lines.push(`${(i + 1).toString().padStart(4, ' ')}  ${this.history[i]}`);
      }
      return new ShellOutput(lines, 0);
    }
    if (name === 'clear') {
      const result: ShellOutput = new ShellOutput([], 0);
      result.clear = true;
      return result;
    }
    if (name === 'help') {
      return new ShellOutput(this.helpLines(), 0);
    }
    if (name === 'true') {
      return new ShellOutput([], 0);
    }
    if (name === 'false') {
      return new ShellOutput([], 1);
    }
    if (name === 'sleep') {
      if (args.length === 0) {
        return new ShellOutput(['ohsh: sleep: missing operand'], 1);
      }
      return new ShellOutput([], 0);
    }
    if (name === 'tee') {
      if (args.length === 0) {
        return new ShellOutput(stdin, 0);
      }
      const target: string = this.absolute(args[0]);
      this.fs.writeText(target, stdin.length > 0 ? stdin.join('\n') + '\n' : '', false);
      return new ShellOutput(stdin, 0);
    }
    return new ShellOutput([`ohsh: ${name}: command not found`], 127);
  }

  private helpLines(): Array<string> {
    return [
      'ohsh — sandbox shell for OHOS Terminal',
      '',
      '  file ops   ls cd pwd cat stat touch mkdir rm rmdir mv cp du df',
      '  text       echo head tail wc grep sort tee',
      '  session    history clear date uname hostname whoami id env exit help',
      '',
      '  syntax     cmd | cmd   cmd > file   cmd >> file   cmd < file   a; b',
      '             $VAR ${VAR} $?   ~   globs: * ?',
      '  examples   ls -lah /docs',
      '             grep -in log /logs/app.txt | wc -l',
      '             stat /docs/readme.txt',
      '             cp /docs/a.txt /docs/b.txt',
    ];
  }

  private requirePath(args: Array<string>, command: string): ShellOutput | null {
    if (args.length === 0) {
      return new ShellOutput([`ohsh: ${command}: missing operand`], 1);
    }
    return null;
  }

  private builtinLs(args: Array<string>): ShellOutput {
    let long: boolean = false;
    let all: boolean = false;
    let human: boolean = false;
    let recursive: boolean = false;
    const targets: Array<string> = [];
    for (let i = 0; i < args.length; i++) {
      const arg: string = args[i];
      if (arg.length > 1 && arg.startsWith('-') && !arg.startsWith('--')) {
        for (let j = 1; j < arg.length; j++) {
          const flag: string = arg.charAt(j);
          if (flag === 'l') {
            long = true;
          } else if (flag === 'a') {
            all = true;
          } else if (flag === 'h') {
            human = true;
          } else if (flag === 'R') {
            recursive = true;
          } else if (flag !== '1') {
            return new ShellOutput([`ls: invalid option -- '${flag}'`], 2);
          }
        }
      } else {
        targets.push(arg);
      }
    }
    const paths: Array<string> = targets.length === 0
      ? [this.fs.cwd]
      : targets.map((target: string): string => this.absolute(target));
    const lines: Array<string> = [];
    let code: number = 0;
    for (let i = 0; i < paths.length; i++) {
      const path: string = paths[i];
      const stat: FileEntry | null = this.fs.stat(path);
      if (stat === null) {
        lines.push(`ls: ${targets.length === 0 ? path : targets[i]}: No such file or directory`);
        code = 1;
        continue;
      }
      if (!stat.isDir || (paths.length > 1 && i === 0)) {
        lines.push(long ? this.longLine(stat, human) : stat.name);
        continue;
      }
      if (paths.length > 1) {
        lines.push(`${paths[i]}:`);
      }
      this.listInto(path, long, all, human, recursive, lines, paths.length > 1 ? '  ' : '');
    }
    return new ShellOutput(lines, code);
  }

  private listInto(path: string, long: boolean, all: boolean, human: boolean,
                   recursive: boolean, lines: Array<string>, indent: string): void {
    let entries: Array<FileEntry> = [];
    try {
      entries = this.fs.list(path);
    } catch (e) {
      lines.push(`ls: ${path}: Permission denied`);
      return;
    }
    entries.sort((a: FileEntry, b: FileEntry): number => {
      if (a.isDir !== b.isDir) {
        return a.isDir ? -1 : 1;
      }
      return naturalCompare(a.name, b.name);
    });
    const shown: Array<FileEntry> = all
      ? entries
      : entries.filter((entry: FileEntry): boolean => !entry.name.startsWith('.'));
    if (!long) {
      const names: Array<string> = shown.map((entry: FileEntry): string =>
        entry.isDir ? `${entry.name}/` : entry.name);
      if (names.length > 0) {
        lines.push(indent + names.join('  '));
      }
      return;
    }
    for (let i = 0; i < shown.length; i++) {
      lines.push(indent + this.longLine(shown[i], human));
    }
    if (recursive) {
      for (let i = 0; i < shown.length; i++) {
        const entry: FileEntry = shown[i];
        if (entry.isDir && !entry.isLink && entry.name !== '.' && entry.name !== '..') {
          lines.push('');
          lines.push(`${indent}${entry.path === '/' ? '/' : entry.path + '/'}:`);
          this.listInto(entry.path, long, all, human, recursive, lines, indent + '  ');
        }
      }
    }
  }

  private longLine(entry: FileEntry, human: boolean): string {
    const size: string = human ? humanSize(entry.size) : `${entry.size}`;
    const owner: string = entry.mode === 0 ? '' : `${entry.uid}:${entry.gid}`;
    const target: string = entry.isLink && entry.linkTarget.length > 0
      ? ` -> ${entry.linkTarget}` : '';
    const name: string = entry.isDir ? `${entry.name}/` : entry.name;
    return `${modeString(entry.mode)} ${size.padStart(9, ' ')} ` +
           `${formatDate(entry.mtime)} ${owner} ${name}${target}`;
  }

  private builtinCd(args: Array<string>): ShellOutput {
    let target: string = args.length === 0 ? (this.env.get('HOME') ?? '/') : args[0];
    if (target === '-') {
      target = this.env.get('OLDPWD') ?? '/';
    }
    const resolved: string = this.absolute(target);
    const stat: FileEntry | null = this.fs.stat(resolved);
    if (stat === null || !stat.isDir) {
      return new ShellOutput([`cd: ${target}: Not a directory`], 1);
    }
    this.env.set('OLDPWD', this.fs.cwd);
    this.fs.cwd = resolved;
    this.env.set('PWD', resolved);
    return new ShellOutput([], 0);
  }

  private builtinCat(args: Array<string>, stdin: Array<string>): ShellOutput {
    let number: boolean = false;
    const files: Array<string> = [];
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '-n') {
        number = true;
      } else {
        files.push(args[i]);
      }
    }
    if (files.length === 0) {
      return new ShellOutput(stdin, 0);
    }
    const lines: Array<string> = [];
    let code: number = 0;
    for (let i = 0; i < files.length; i++) {
      try {
        const content: string = this.fs.readText(this.absolute(files[i]));
        lines.push(...this.readLines(content));
      } catch (e) {
        lines.push(`cat: ${files[i]}: No such file or directory`);
        code = 1;
      }
    }
    if (!number) {
      return new ShellOutput(lines, code);
    }
    const numbered: Array<string> = [];
    for (let i = 0; i < lines.length; i++) {
      numbered.push(`${(i + 1).toString().padStart(6, ' ')}  ${lines[i]}`);
    }
    return new ShellOutput(numbered, code);
  }

  private builtinEcho(args: Array<string>): ShellOutput {
    let i: number = 0;
    let newline: boolean = true;
    if (args.length > 0 && args[0] === '-n') {
      newline = false;
      i = 1;
    }
    const text: string = args.slice(i).join(' ').replace(/\\n/g, '\n').replace(/\\t/g, '\t');
    return new ShellOutput(newline ? text.split('\n') : [text], 0);
  }

  private builtinMkdir(args: Array<string>): ShellOutput {
    const missing: ShellOutput | null = this.requirePath(args, 'mkdir');
    if (missing !== null) {
      return missing;
    }
    let parents: boolean = false;
    const paths: Array<string> = [];
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '-p') {
        parents = true;
      } else {
        paths.push(args[i]);
      }
    }
    const errors: Array<string> = [];
    for (let i = 0; i < paths.length; i++) {
      let target: string = this.absolute(paths[i]);
      const chain: Array<string> = [];
      if (!parents) {
        chain.push(target);
      } else {
        while (target !== '/' && this.fs.stat(target) === null) {
          chain.unshift(target);
          target = parentPath(target);
        }
      }
      for (let j = 0; j < chain.length; j++) {
        try {
          this.fs.mkdir(chain[j]);
        } catch (e) {
          errors.push(`mkdir: ${chain[j]}: File exists`);
        }
      }
    }
    return new ShellOutput(errors, errors.length > 0 ? 1 : 0);
  }

  private builtinRm(args: Array<string>, dirOnly: boolean): ShellOutput {
    const names: Array<string> = [];
    let recursive: boolean = false;
    let force: boolean = false;
    for (let i = 0; i < args.length; i++) {
      const arg: string = args[i];
      if (arg.startsWith('-') && arg.length > 1) {
        if (arg.indexOf('r') >= 0 || arg.indexOf('R') >= 0) {
          recursive = true;
        }
        if (arg.indexOf('f') >= 0) {
          force = true;
        }
      } else {
        names.push(arg);
      }
    }
    if (names.length === 0) {
      return new ShellOutput([`${dirOnly ? 'rmdir' : 'rm'}: missing operand`], 1);
    }
    const errors: Array<string> = [];
    for (let i = 0; i < names.length; i++) {
      const target: string = this.absolute(names[i]);
      if (target === '/' || target === this.fs.cwd) {
        errors.push(`rm: refusing to remove '${names[i]}'`);
        continue;
      }
      const stat: FileEntry | null = this.fs.stat(target);
      if (stat === null) {
        if (!force) {
          errors.push(`rm: ${names[i]}: No such file or directory`);
        }
        continue;
      }
      if (stat.isDir && !recursive) {
        errors.push(`rm: ${names[i]}: is a directory`);
        continue;
      }
      try {
        this.fs.remove(target, stat.isDir);
      } catch (e) {
        errors.push(`rm: ${names[i]}: cannot remove`);
      }
    }
    return new ShellOutput(errors, errors.length > 0 ? 1 : 0);
  }

  private builtinMv(args: Array<string>): ShellOutput {
    if (args.length < 2) {
      return new ShellOutput(['mv: missing destination operand'], 1);
    }
    const dest: string = this.absolute(args[args.length - 1]);
    const destStat: FileEntry | null = this.fs.stat(dest);
    const sources: Array<string> = args.slice(0, args.length - 1);
    if (sources.length > 1 && (destStat === null || !destStat.isDir)) {
      return new ShellOutput(['mv: target is not a directory'], 1);
    }
    const errors: Array<string> = [];
    for (let i = 0; i < sources.length; i++) {
      const from: string = this.absolute(sources[i]);
      const to: string = destStat !== null && destStat.isDir
        ? joinPath(dest, baseName(from)) : dest;
      try {
        this.fs.rename(from, to);
      } catch (e) {
        errors.push(`mv: ${sources[i]}: cannot move`);
      }
    }
    return new ShellOutput(errors, errors.length > 0 ? 1 : 0);
  }

  private builtinCp(args: Array<string>): ShellOutput {
    if (args.length < 2) {
      return new ShellOutput(['cp: missing destination operand'], 1);
    }
    const dest: string = this.absolute(args[args.length - 1]);
    const destStat: FileEntry | null = this.fs.stat(dest);
    const sources: Array<string> = args.slice(0, args.length - 1);
    if (sources.length > 1 && (destStat === null || !destStat.isDir)) {
      return new ShellOutput(['cp: target is not a directory'], 1);
    }
    const errors: Array<string> = [];
    for (let i = 0; i < sources.length; i++) {
      const from: string = this.absolute(sources[i]);
      const to: string = destStat !== null && destStat.isDir
        ? joinPath(dest, baseName(from)) : dest;
      try {
        this.fs.copy(from, to);
      } catch (e) {
        errors.push(`cp: ${sources[i]}: cannot copy`);
      }
    }
    return new ShellOutput(errors, errors.length > 0 ? 1 : 0);
  }

  private builtinTouch(args: Array<string>): ShellOutput {
    const missing: ShellOutput | null = this.requirePath(args, 'touch');
    if (missing !== null) {
      return missing;
    }
    const errors: Array<string> = [];
    for (let i = 0; i < args.length; i++) {
      const target: string = this.absolute(args[i]);
      if (this.fs.stat(target) === null) {
        try {
          this.fs.writeText(target, '', false);
        } catch (e) {
          errors.push(`touch: ${args[i]}: cannot create`);
        }
      }
    }
    return new ShellOutput(errors, errors.length > 0 ? 1 : 0);
  }

  private builtinHeadTail(name: string, args: Array<string>, stdin: Array<string>): ShellOutput {
    let count: number = 10;
    const files: Array<string> = [];
    for (let i = 0; i < args.length; i++) {
      const arg: string = args[i];
      if (arg === '-n' && i + 1 < args.length) {
        count = parseInt(args[i + 1], 10);
        i++;
      } else if (arg.startsWith('-') && arg.length > 1) {
        const parsed: number = parseInt(arg.substring(1), 10);
        if (!isNaN(parsed)) {
          count = parsed;
        }
      } else {
        files.push(arg);
      }
    }
    if (isNaN(count) || count < 0) {
      return new ShellOutput([`${name}: invalid line count`], 1);
    }
    let lines: Array<string> = stdin;
    if (files.length > 0) {
      try {
        lines = this.readLines(this.fs.readText(this.absolute(files[0])));
      } catch (e) {
        return new ShellOutput([`${name}: ${files[0]}: No such file or directory`], 1);
      }
    }
    return new ShellOutput(name === 'head'
      ? lines.slice(0, count)
      : lines.slice(Math.max(0, lines.length - count)), 0);
  }

  private builtinWc(args: Array<string>, stdin: Array<string>): ShellOutput {
    const flags: string = args.filter((arg: string): boolean => arg.startsWith('-')).join('');
    const files: Array<string> = args.filter((arg: string): boolean => !arg.startsWith('-'));
    const wantLines: boolean = flags.length === 0 || flags.indexOf('l') >= 0;
    const wantWords: boolean = flags.length === 0 || flags.indexOf('w') >= 0;
    const wantBytes: boolean = flags.length === 0 || flags.indexOf('c') >= 0;
    const measure = (text: string, label: string): string => {
      const lines: Array<string> = this.readLines(text);
      const words: Array<string> = text.split(/\s+/)
        .filter((word: string): boolean => word.length > 0);
      const parts: Array<string> = [];
      if (wantLines) {
        parts.push(`${lines.length}`.padStart(7, ' '));
      }
      if (wantWords) {
        parts.push(`${words.length}`.padStart(7, ' '));
      }
      if (wantBytes) {
        parts.push(`${text.length}`.padStart(7, ' '));
      }
      return parts.join('') + (label.length > 0 ? ` ${label}` : '');
    };
    if (files.length === 0) {
      return new ShellOutput([measure(stdin.length > 0 ? stdin.join('\n') + '\n' : '', '')], 0);
    }
    const lines: Array<string> = [];
    let code: number = 0;
    for (let i = 0; i < files.length; i++) {
      try {
        lines.push(measure(this.fs.readText(this.absolute(files[i])), files[i]));
      } catch (e) {
        lines.push(`wc: ${files[i]}: No such file or directory`);
        code = 1;
      }
    }
    return new ShellOutput(lines, code);
  }

  private builtinGrep(args: Array<string>, stdin: Array<string>): ShellOutput {
    let ignoreCase: boolean = false;
    let invert: boolean = false;
    let number: boolean = false;
    const rest: Array<string> = [];
    for (let i = 0; i < args.length; i++) {
      const arg: string = args[i];
      if (arg.length > 1 && arg.startsWith('-')) {
        if (arg.indexOf('i') >= 0) {
          ignoreCase = true;
        }
        if (arg.indexOf('v') >= 0) {
          invert = true;
        }
        if (arg.indexOf('n') >= 0) {
          number = true;
        }
      } else {
        rest.push(arg);
      }
    }
    if (rest.length === 0) {
      return new ShellOutput(['grep: missing pattern'], 2);
    }
    const pattern: string = rest[0];
    const files: Array<string> = rest.slice(1);
    let source: Array<string> = stdin;
    let label: string = '';
    if (files.length > 0) {
      source = [];
      for (let i = 0; i < files.length; i++) {
        try {
          const content: Array<string> = this.readLines(this.fs.readText(this.absolute(files[i])));
          for (let j = 0; j < content.length; j++) {
            source.push(files.length > 1 ? `${files[i]}:${content[j]}` : content[j]);
          }
        } catch (e) {
          return new ShellOutput([`grep: ${files[i]}: No such file or directory`], 2);
        }
      }
      label = files[0];
    }
    const needle: string = ignoreCase ? pattern.toLowerCase() : pattern;
    const out: Array<string> = [];
    for (let i = 0; i < source.length; i++) {
      const hay: string = ignoreCase ? source[i].toLowerCase() : source[i];
      const hit: boolean = hay.indexOf(needle) >= 0;
      if (hit !== invert) {
        out.push(number ? `${i + 1}:${source[i]}` : source[i]);
      }
    }
    return new ShellOutput(out, out.length > 0 ? 0 : 1);
  }

  private builtinSort(args: Array<string>, stdin: Array<string>): ShellOutput {
    let reverse: boolean = false;
    let numeric: boolean = false;
    const files: Array<string> = [];
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '-r') {
        reverse = true;
      } else if (args[i] === '-n') {
        numeric = true;
      } else if (!args[i].startsWith('-')) {
        files.push(args[i]);
      }
    }
    let lines: Array<string> = stdin;
    if (files.length > 0) {
      try {
        lines = this.readLines(this.fs.readText(this.absolute(files[0])));
      } catch (e) {
        return new ShellOutput([`sort: ${files[0]}: No such file or directory`], 1);
      }
    }
    const sorted: Array<string> = lines.slice();
    sorted.sort((a: string, b: string): number => {
      if (numeric) {
        const na: number = parseFloat(a);
        const nb: number = parseFloat(b);
        if (!isNaN(na) && !isNaN(nb) && na !== nb) {
          return na < nb ? -1 : 1;
        }
      }
      return naturalCompare(a, b);
    });
    return new ShellOutput(reverse ? sorted.reverse() : sorted, 0);
  }

  private builtinStat(args: Array<string>): ShellOutput {
    const missing: ShellOutput | null = this.requirePath(args, 'stat');
    if (missing !== null) {
      return missing;
    }
    const target: string = this.absolute(args[0]);
    const entry: FileEntry | null = this.fs.stat(target);
    if (entry === null) {
      return new ShellOutput([`stat: ${args[0]}: No such file or directory`], 1);
    }
    const lines: Array<string> = [];
    lines.push(`  File: ${entry.path}`);
    lines.push(`  Size: ${entry.size}\tBlocks: 0\tIO Block: 4096`);
    lines.push(`  Type: ${this.typeName(entry)}`);
    lines.push(`  Mode: (${modeOctalSafe(entry.mode)}) ${modeString(entry.mode)}`);
    lines.push(`  Uid: (${entry.uid})  Gid: (${entry.gid})`);
    lines.push(`Access: ${formatDate(entry.mtime)}`);
    if (entry.isLink) {
      let link: string = entry.linkTarget;
      if (link.length === 0) {
        try {
          link = this.fs.readlink(target);
        } catch (e) {
          link = '?';
        }
      }
      lines.push(`  Link: ${link}`);
    }
    return new ShellOutput(lines, 0);
  }

  private typeName(entry: FileEntry): string {
    if (entry.isLink) {
      return 'symbolic link';
    }
    return entry.isDir ? 'directory' : 'regular file';
  }

  private builtinDu(args: Array<string>): ShellOutput {
    const human: boolean = args.indexOf('-h') >= 0 || args.indexOf('-sh') >= 0;
    const targets: Array<string> = args.filter((arg: string): boolean => !arg.startsWith('-'));
    const roots: Array<string> = targets.length === 0
      ? [this.fs.cwd]
      : targets.map((arg: string): string => this.absolute(arg));
    const lines: Array<string> = [];
    let code: number = 0;
    for (let i = 0; i < roots.length; i++) {
      const size: number = this.sizeOf(roots[i]);
      if (size < 0) {
        lines.push(`du: ${targets[i] ?? roots[i]}: No such file or directory`);
        code = 1;
        continue;
      }
      const shown: string = human ? humanSize(size) : `${Math.ceil(size / 1024)}`;
      lines.push(`${shown.padStart(6, ' ')}\t${targets[i] ?? roots[i]}`);
    }
    return new ShellOutput(lines, code);
  }

  private sizeOf(path: string): number {
    const entry: FileEntry | null = this.fs.stat(path);
    if (entry === null) {
      return -1;
    }
    if (!entry.isDir) {
      return entry.size;
    }
    let total: number = 0;
    let children: Array<FileEntry> = [];
    try {
      children = this.fs.list(path);
    } catch (e) {
      return 0;
    }
    for (let i = 0; i < children.length; i++) {
      total += this.sizeOf(children[i].path);
    }
    return total;
  }

  private builtinDf(): ShellOutput {
    const row: string = 'Filesystem      Size    Used   Avail   Use%   Mounted on';
    return new ShellOutput([
      row,
      '/dev/sandbox    4096M       ?       ?      ?   /',
    ], 0);
  }

  // ------------------------------------------------------------- completion

  complete(line: string, caret: number): Completion {
    const before: string = line.substring(0, caret);
    const match: RegExpMatchArray | null = before.match(/([^\s]*)$/);
    const token: string = match === null ? '' : (match[1] ?? '');
    const tokenStart: number = caret - token.length;
    const isCommand: boolean = /^\s*$/.test(before.substring(0, tokenStart)) &&
      before.indexOf('|') < 0 && before.indexOf(';') < 0;

    if (isCommand) {
      const hits: Array<string> = COMMANDS.filter((name: string): boolean =>
        name.startsWith(token));
      hits.sort(naturalCompare);
      const completed: string = this.commonPrefix(hits);
      if (hits.length === 1) {
        return new Completion(line.substring(0, tokenStart) + hits[0] + ' ' +
          line.substring(caret), tokenStart + hits[0].length + 1, hits);
      }
      return new Completion(line.substring(0, tokenStart) + completed +
        line.substring(caret), tokenStart + completed.length, hits);
    }

    const slash: number = token.lastIndexOf('/');
    const dirPart: string = slash >= 0 ? token.substring(0, slash + 1) : '';
    const prefix: string = slash >= 0 ? token.substring(slash + 1) : token;
    const dirPath: string = this.absolute(dirPart.length > 0 ? dirPart : '.');
    let entries: Array<FileEntry> = [];
    try {
      entries = this.fs.list(dirPath);
    } catch (e) {
      return new Completion(line, caret, []);
    }
    const hits: Array<string> = [];
    for (let i = 0; i < entries.length; i++) {
      const entry: FileEntry = entries[i];
      if (!entry.name.startsWith(prefix)) {
        continue;
      }
      hits.push(dirPart + entry.name + (entry.isDir ? '/' : ''));
    }
    hits.sort(naturalCompare);
    if (hits.length === 0) {
      return new Completion(line, caret, []);
    }
    if (hits.length === 1) {
      const single: string = hits[0];
      return new Completion(line.substring(0, tokenStart) + single + ' ' +
        line.substring(caret), tokenStart + single.length + 1, hits);
    }
    const completed: string = this.commonPrefix(hits);
    return new Completion(line.substring(0, tokenStart) + completed +
      line.substring(caret), tokenStart + completed.length, hits);
  }

  private commonPrefix(values: Array<string>): string {
    if (values.length === 0) {
      return '';
    }
    let prefix: string = values[0];
    for (let i = 1; i < values.length; i++) {
      while (!values[i].startsWith(prefix) && prefix.length > 0) {
        prefix = prefix.substring(0, prefix.length - 1);
      }
    }
    return prefix;
  }
}

function modeOctalSafe(mode: number): string {
  return (mode & 0o7777).toString(8).padStart(4, '0');
}
