import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';

export interface AccountVoiceInput {
  favorites: string[];
  history: string[];
  favoriteCounts: Record<string, number>;
}

export interface AccountVoiceOperation {
  id: string;
  kind: string;
  text: string;
  data?: AccountVoiceInput;
}

export interface AccountVoiceRequest {
  operations: AccountVoiceOperation[];
}

function emptyState(): AccountVoiceInput {
  return { favorites: [], history: [], favoriteCounts: {} };
}

function copyState(state: AccountVoiceInput): AccountVoiceInput {
  return JSON.parse(JSON.stringify(state)) as AccountVoiceInput;
}

function applyOperation(state: AccountVoiceInput, op: AccountVoiceOperation): void {
  if (op.kind === 'addFavorite') {
    if (state.favorites.indexOf(op.text) < 0) { state.favorites.push(op.text); }
  } else if (op.kind === 'removeFavorite') {
    state.favorites = state.favorites.filter((text: string) => text !== op.text);
    const counts: Record<string, number> = {};
    const keys: string[] = Object.keys(state.favoriteCounts);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== op.text) { counts[keys[i]] = state.favoriteCounts[keys[i]]; }
    }
    state.favoriteCounts = counts;
  } else if (op.kind === 'clearFavorites') {
    state.favorites = [];
    state.favoriteCounts = {};
  } else if (op.kind === 'useFavorite') {
    if (state.favorites.indexOf(op.text) >= 0) {
      const count: number = state.favoriteCounts[op.text];
      state.favoriteCounts[op.text] = (count !== undefined ? count : 0) + 1;
    }
  } else if (op.kind === 'recordHistory') {
    state.history = state.history.filter((text: string) => text !== op.text);
    state.history.push(op.text);
    state.history = state.history.slice(-40);
  } else if (op.kind === 'removeHistory') {
    state.history = state.history.filter((text: string) => text !== op.text);
  } else if (op.kind === 'clearHistory') {
    state.history = [];
  }
}

// Durable edits belong to one account and survive offline refreshes/restarts.
export class VoiceInputAccount {
  state: AccountVoiceInput;
  private prefs: preferences.Preferences;
  private owner: string;
  private migrated: boolean;
  private queue: AccountVoiceOperation[];

  constructor(prefs: preferences.Preferences, legacy: AccountVoiceInput) {
    this.prefs = prefs;
    this.state = legacy;
    this.owner = prefs.getSync('voiceInputOwner', '') as string;
    this.migrated = prefs.getSync('voiceInputMigrated', false) as boolean;
    try {
      this.queue = JSON.parse(prefs.getSync('voiceInputOperations', '[]') as string) as AccountVoiceOperation[];
    } catch (e) { this.queue = []; }
  }

  private persist(): void {
    this.prefs.putSync('voiceInputOwner', this.owner);
    this.prefs.putSync('voiceInputMigrated', this.migrated);
    this.prefs.putSync('voiceInputOperations', JSON.stringify(this.queue));
    this.prefs.putSync('favorites', JSON.stringify(this.state.favorites));
    this.prefs.putSync('favoriteCounts', JSON.stringify(this.state.favoriteCounts));
    this.prefs.putSync('history', JSON.stringify(this.state.history));
    this.prefs.flush().catch(() => {});
  }

  prepareAccount(username: string, previous: string = ''): void {
    const old: string = this.owner.length > 0 ? this.owner : previous;
    if (old.length > 0 && old !== username) {
      this.state = emptyState(); this.queue = []; this.migrated = false;
    }
    this.owner = username;
    this.persist();
  }

  perform(kind: string, text: string = ''): void {
    const trimmed: string = text.trim();
    if (kind.indexOf('clear') !== 0 && trimmed.length === 0) { return; }
    const op: AccountVoiceOperation = { id: util.generateRandomUUID(true), kind: kind, text: trimmed };
    applyOperation(this.state, op);
    this.queue.push(op);
    this.persist();
  }

  adopt(remote: AccountVoiceInput | null | undefined, username: string): void {
    this.prepareAccount(username);
    if (!this.migrated) {
      if (remote === null || remote === undefined) {
        const seed: AccountVoiceOperation = {
          id: util.generateRandomUUID(true), kind: 'seed', text: '', data: copyState(this.state)
        };
        this.queue = [seed];
      }
      this.migrated = true;
    }
    let base: AccountVoiceInput = this.state;
    if (remote !== null && remote !== undefined) { base = remote; }
    else {
      for (let i = 0; i < this.queue.length; i++) {
        if (this.queue[i].kind === 'seed' && this.queue[i].data !== undefined) {
          base = this.queue[i].data!; break;
        }
      }
    }
    this.state = copyState(base);
    for (let i = 0; i < this.queue.length; i++) { applyOperation(this.state, this.queue[i]); }
    this.persist();
  }

  pending(username: string): AccountVoiceOperation[] {
    return this.owner === username ? this.queue.slice(0, 100) : [];
  }

  acknowledge(sent: AccountVoiceOperation[], remote: AccountVoiceInput, username: string): void {
    if (this.owner !== username) { return; }
    const ids: string[] = sent.map((op: AccountVoiceOperation) => op.id);
    this.queue = this.queue.filter((op: AccountVoiceOperation) => ids.indexOf(op.id) < 0);
    this.state = copyState(remote);
    for (let i = 0; i < this.queue.length; i++) { applyOperation(this.state, this.queue[i]); }
    this.persist();
  }
}
