import preferences from '@ohos.data.preferences';

const STORE = 'hvolt-ide';

// The shell keeps only what the user changed by hand: which project was open and which
// device channel to talk to. Everything else is read back from the filesystem.
export async function readPref(key: string, def: string): Promise<string> {
  try {
    const store = await preferences.getPreferences(getContext(), STORE);
    const value = await store.get(key, def);
    return value as string;
  } catch (e) {
    return def;
  }
}

export async function writePref(key: string, value: string): Promise<void> {
  try {
    const store = await preferences.getPreferences(getContext(), STORE);
    await store.put(key, value);
    await store.flush();
  } catch (e) {
  }
}
