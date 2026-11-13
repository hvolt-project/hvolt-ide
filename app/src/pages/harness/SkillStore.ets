// Where skills live, and which one wins.
//
// Two layers. Shipped skills sit in the bundle's rawfile and cannot change; the writable layer is a
// directory in the app sandbox, which is what lets the assistant author and revise its own skills.
// A name in the writable layer shadows the shipped one of the same name, so a revision is a new
// file rather than an edit to something the bundle owns.

import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { SkillEntry, parseSkill } from './loop/Skills';

const BUILTIN_DIR: string = 'harness/skills';
const WORKSPACE_DIR: string = 'skills';
const FILE_NAME: string = 'SKILL.md';

export class SkillStore {
  /** Sandbox directory holding writable skills. */
  private workspaceRoot: string;

  constructor(filesDir: string) {
    this.workspaceRoot = filesDir + '/' + WORKSPACE_DIR;
  }

  /** Names of the writable skills, so the tool surface can describe what is editable. */
  workspacePath(): string {
    return this.workspaceRoot;
  }

  private async readBuiltin(name: string): Promise<string> {
    try {
      const bytes: Uint8Array = await getContext().resourceManager.getRawFileContent(BUILTIN_DIR + '/' + name + '/' + FILE_NAME);
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(bytes);
    } catch (e) {
      return '';
    }
  }

  private readWorkspace(name: string): string {
    try {
      const path = this.workspaceRoot + '/' + name + '/' + FILE_NAME;
      if (!fs.accessSync(path)) {
        return '';
      }
      return fs.readTextSync(path);
    } catch (e) {
      return '';
    }
  }

  /** Directory names under a path, empty when it does not exist or cannot be read. */
  private listDirs(root: string): string[] {
    const out: string[] = [];
    try {
      if (!fs.accessSync(root)) {
        return out;
      }
      for (const entry of fs.listFileSync(root)) {
        const full = root + '/' + entry;
        try {
          if (fs.statSync(full).isDirectory()) {
            out.push(entry);
          }
        } catch (e) {
        }
      }
    } catch (e) {
    }
    return out;
  }

  /** Shipped skill directory names, read from the bundle's rawfile listing. */
  private async builtinNames(): Promise<string[]> {
    const out: string[] = [];
    try {
      const names: string[] = await getContext().resourceManager.getRawFileList(BUILTIN_DIR);
      for (const name of names) {
        out.push(name);
      }
    } catch (e) {
    }
    return out;
  }

  /**
   * Every available skill, writable layer first so it shadows the shipped file of the same name.
   * A skill whose file cannot be read is skipped rather than listed and then failing to load.
   */
  async entries(): Promise<SkillEntry[]> {
    const seen: Set<string> = new Set<string>();
    const out: SkillEntry[] = [];
    for (const name of this.listDirs(this.workspaceRoot)) {
      const text = this.readWorkspace(name);
      if (text.length === 0) {
        continue;
      }
      out.push(parseSkill(name, text, 'workspace'));
      seen.add(name);
    }
    for (const name of await this.builtinNames()) {
      if (seen.has(name)) {
        continue;
      }
      const text = await this.readBuiltin(name);
      if (text.length === 0) {
        continue;
      }
      out.push(parseSkill(name, text, 'builtin'));
    }
    return out;
  }

  /** The full text of one skill, writable layer first. '' when it does not exist. */
  async read(name: string): Promise<string> {
    const writable = this.readWorkspace(name);
    if (writable.length > 0) {
      return writable;
    }
    return await this.readBuiltin(name);
  }
}
