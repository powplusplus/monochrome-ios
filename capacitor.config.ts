import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
    appId: 'tf.monochrome.music',
    appName: 'Monochrome Music',
    webDir: 'dist',
    server: {
        url: 'https://monochrome.tf',
        allowNavigation: [
            'monochrome.tf',
            '*.monochrome.tf',
            'discord.com',
            '*.discord.com',
            'github.com',
            '*.github.com',
        ],
        errorPath: 'index.html',
    },
    assets: {
        iconBackgroundColor: '#000000',
        iconBackgroundColorDark: '#000000',
        splashBackgroundColor: '#000000',
        splashBackgroundColorDark: '#000000',
    },
};

export default config;
