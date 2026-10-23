import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.adamcopeland.snoretracker',
  appName: 'Snore Tracker',
  webDir: 'www',
  backgroundColor: '#1e1b4b',
  ios: {
    contentInset: 'never'
  }
};

export default config;
