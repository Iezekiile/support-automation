<?php
error_reporting(E_ALL);
ini_set('display_errors', 1);

/**
 * Plain-text version of the image download/save tester.
 * Designed for CLI / console output (no HTML/CSS).
 */

$NL = PHP_EOL;

function out($text = '') {
    echo $text . PHP_EOL;
}

function kv($key, $value, $pad = 28) {
    printf("%-{$pad}s : %s" . PHP_EOL, $key, $value);
}

function hr($char = '-', $len = 72) {
    echo str_repeat($char, $len) . PHP_EOL;
}

function human_filesize($bytes, $decimals = 2) {
    $size = ['B','KB','MB','GB','TB'];
    $factor = floor((strlen($bytes) - 1) / 3);
    return sprintf("%.{$decimals}f %s", $bytes / pow(1024, $factor), $size[$factor]);
}

function printable_snippet($data, $len = 200) {
    $s = substr($data, 0, $len);
    // Replace non-printable characters with dots
    $s = preg_replace('/[^\x20-\x7E]/', '.', $s);
    return $s;
}

// Config
$testUrls = [
    'https://picsum.photos/200/300',
    'https://niala.com.ua/image/catalog/kb-a4f-btp2.jpg'
    'https://niala.com.ua/image/catalog/prod/kiborg/zymovyi-maskuvalnyi-vodovidshtokhuvalnyi-taktychnyi-kostium-kiborg-multicam-alpine-29735080882236_+8d12af5aa9.jpg'
];

$testDir = __DIR__ . DIRECTORY_SEPARATOR . 'test_images' . DIRECTORY_SEPARATOR;

// Header
hr('=');
out('Тест завантаження та збереження зображень (plain text)');
hr('=');
out();

// Ensure directory
if (!is_dir($testDir)) {
    $created = @mkdir($testDir, 0755, true);
    if ($created) {
        kv('Директорію створено', $testDir);
    } else {
        kv('Не вдалося створити директорію', $testDir);
    }
} else {
    kv('Директорія', $testDir);
}

$writable = is_writable($testDir);
kv('Права на запис', $writable ? 'YES' : 'NO');
kv('Права (octal)', substr(sprintf('%o', fileperms($testDir)), -4));
kv('Поточний користувач', get_current_user());
out();

hr();

// Tests
foreach ($testUrls as $index => $url) {
    $num = $index + 1;
    $filename = $testDir . 'test_image_' . $num . '.jpg';

    out("Тест #{$num}");
    hr();

    kv('Джерело', $url);

    // --- Download
    $start = microtime(true);
    $imageData = @file_get_contents($url);
    $end = microtime(true);

    if ($imageData === false) {
        $err = error_get_last();
        kv('Завантаження', 'FAILED');
        kv('Помилка', $err['message'] ?? 'Невідома помилка');
        if (!function_exists('curl_init')) {
            kv('CURL', 'не встановлено (можливо потрібно для деяких середовищ)');
        }
        out();
        continue;
    }

    $downloadMs = round(($end - $start) * 1000, 2);
    $sizeBytes = strlen($imageData);

    // MIME
    $finfo = new finfo(FILEINFO_MIME_TYPE);
    $mime = $finfo->buffer($imageData);

    kv('Завантаження', 'OK');
    kv('Розмір (байт)', number_format($sizeBytes));
    kv('Розмір (зручний)', human_filesize($sizeBytes));
    kv('Час завантаження', $downloadMs . ' ms');
    kv('MIME', $mime);

    $isImage = in_array($mime, ['image/jpeg','image/png','image/gif','image/webp','image/jpg']);
    kv('Чи зображення', $isImage ? 'YES' : 'NO');

    if (!$isImage) {
        out();
        out('Перші 200 символів відповіді (не-зображення):');
        out(printable_snippet($imageData, 200));
        out();
        continue;
    }

    // --- Save
    $bytesWritten = @file_put_contents($filename, $imageData);
    if ($bytesWritten === false) {
        $err = error_get_last();
        kv('Збереження', 'FAILED');
        kv('Помилка', $err['message'] ?? 'Невідома помилка');
        $dir = dirname($filename);
        kv('Директорія існує', is_dir($dir) ? 'YES' : 'NO');
        kv('Доступна для запису', is_writable($dir) ? 'YES' : 'NO');
        kv('Повний шлях', $filename);
    } else {
        $savedSize = file_exists($filename) ? filesize($filename) : 0;
        kv('Збережено байт', number_format($bytesWritten));
        kv('Файл існує', file_exists($filename) ? 'YES' : 'NO');
        kv('Розмір на диску', number_format($savedSize));
        kv('Розміри співпадають', ($savedSize == $sizeBytes) ? 'YES' : 'NO');
        kv('Повний шлях', $filename);

        // Optional: if DOCUMENT_ROOT is set, provide suggested web path
        if (!empty($_SERVER['DOCUMENT_ROOT'])) {
            $docRoot = realpath($_SERVER['DOCUMENT_ROOT']);
            $realFile = realpath($filename);
            if ($docRoot !== false && $realFile !== false && strpos($realFile, $docRoot) === 0) {
                $webPath = str_replace(DIRECTORY_SEPARATOR, '/', substr($realFile, strlen($docRoot)));
                if ($webPath === '' || $webPath[0] !== '/') $webPath = '/' . ltrim($webPath, '/');
                kv('Suggested web path', $webPath);
            }
        }
    }

    out();
    hr();
    out();
}

// System info
out('Системна інформація:');
hr();
kv('PHP версія', phpversion());
kv('allow_url_fopen', ini_get('allow_url_fopen') ? 'ON' : 'OFF');
kv('max_execution_time', ini_get('max_execution_time') . ' сек');
kv('memory_limit', ini_get('memory_limit'));
kv('upload_max_filesize', ini_get('upload_max_filesize'));
kv('Поточна директорія', getcwd());
kv('DOCUMENT_ROOT', $_SERVER['DOCUMENT_ROOT'] ?? '(not set)');
hr();

out('Результат тестування:');
kv('Перевірте директорію', $testDir);
out();
out('Якщо файли збереглися — file_put_contents працює.');
out();
hr('=');
