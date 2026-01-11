<?php
error_reporting(E_ALL);
ini_set('display_errors', 1);

echo "<h2>Тест завантаження та збереження зображень</h2>";

// URL для тестування
$testUrls = [
    'https://picsum.photos/200/300',
    'https://niala.com.ua/image/catalog/kb-a4f-btp2.jpg'
];

// Директорія для збереження
$testDir = __DIR__ . '/test_images/';

// Створити директорію якщо не існує
if (!is_dir($testDir)) {
    mkdir($testDir, 0755, true);
    echo "✓ Директорію створено: $testDir<br><br>";
} else {
    echo "✓ Директорія існує: $testDir<br><br>";
}

// Перевірка прав на запис
if (!is_writable($testDir)) {
    echo "❌ <strong>ПОМИЛКА:</strong> Немає прав на запис в директорію $testDir<br>";
    echo "Поточний користувач: " . get_current_user() . "<br>";
    echo "Права директорії: " . substr(sprintf('%o', fileperms($testDir)), -4) . "<br><br>";
} else {
    echo "✓ Директорія доступна для запису<br><br>";
}

echo "<hr>";

foreach ($testUrls as $index => $url) {
    $num = $index + 1;
    echo "<h3>Тест #{$num}: $url</h3>";
    
    $filename = $testDir . 'test_image_' . $num . '.jpg';
    
    // === ТЕСТ 1: file_get_contents ===
    echo "<strong>1. Тест file_get_contents($url)</strong><br>";
    
    $startTime = microtime(true);
    $imageData = @file_get_contents($url);
    $endTime = microtime(true);
    
    if ($imageData === false) {
        $error = error_get_last();
        echo "❌ ПОМИЛКА: Не вдалося завантажити<br>";
        echo "Деталі: " . ($error['message'] ?? 'Невідома помилка') . "<br>";
        
        // Додаткова інформація
        if (!function_exists('curl_init')) {
            echo "⚠️ CURL не встановлено<br>";
        }
        
        echo "<br>";
        continue;
    }
    
    $downloadTime = round(($endTime - $startTime) * 1000, 2);
    $fileSize = strlen($imageData);
    
    echo "✓ Успішно завантажено<br>";
    echo "├─ Розмір: " . number_format($fileSize) . " байт (" . round($fileSize/1024, 2) . " KB)<br>";
    echo "├─ Час завантаження: {$downloadTime} мс<br>";
    
    // Перевірка чи це дійсно зображення
    $finfo = new finfo(FILEINFO_MIME_TYPE);
    $mimeType = $finfo->buffer($imageData);
    echo "├─ MIME тип: $mimeType<br>";
    
    if (!in_array($mimeType, ['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/jpg'])) {
        echo "❌ <strong>УВАГА:</strong> Це НЕ зображення!<br>";
        echo "Перші 200 символів:<br>";
        echo "<pre>" . htmlspecialchars(substr($imageData, 0, 200)) . "</pre><br>";
        continue;
    }
    
    echo "✓ Підтверджено: це зображення<br><br>";
    
    // === ТЕСТ 2: file_put_contents ===
    echo "<strong>2. Тест file_put_contents('$filename')</strong><br>";
    
    $bytesWritten = @file_put_contents($filename, $imageData);
    
    if ($bytesWritten === false) {
        $error = error_get_last();
        echo "❌ ПОМИЛКА: Не вдалося зберегти файл<br>";
        echo "Деталі: " . ($error['message'] ?? 'Невідома помилка') . "<br>";
        
        // Детальна діагностика
        $dir = dirname($filename);
        echo "<strong>Діагностика:</strong><br>";
        echo "├─ Директорія існує: " . (is_dir($dir) ? 'ТАК' : 'НІ') . "<br>";
        echo "├─ Директорія доступна для запису: " . (is_writable($dir) ? 'ТАК' : 'НІ') . "<br>";
        echo "├─ Повний шлях: $filename<br>";
        
    } else {
        echo "✓ Успішно збережено<br>";
        echo "├─ Записано байт: " . number_format($bytesWritten) . "<br>";
        echo "├─ Файл існує: " . (file_exists($filename) ? 'ТАК' : 'НІ') . "<br>";
        
        if (file_exists($filename)) {
            $savedSize = filesize($filename);
            echo "├─ Розмір файлу на диску: " . number_format($savedSize) . " байт<br>";
            echo "└─ Розміри співпадають: " . ($savedSize == $fileSize ? '✓ ТАК' : '❌ НІ') . "<br>";
            
            // Показати зображення якщо це веб-доступна директорія
            $webPath = str_replace($_SERVER['DOCUMENT_ROOT'], '', $filename);
            if (strpos($filename, $_SERVER['DOCUMENT_ROOT']) === 0) {
                echo "<br><img src='$webPath' style='max-width: 300px; border: 1px solid #ccc;'><br>";
            }
        }
    }
    
    echo "<hr>";
}

// === ДОДАТКОВА ІНФОРМАЦІЯ ===
echo "<h3>Системна інформація</h3>";
echo "PHP версія: " . phpversion() . "<br>";
echo "allow_url_fopen: " . (ini_get('allow_url_fopen') ? 'ON' : 'OFF') . "<br>";
echo "max_execution_time: " . ini_get('max_execution_time') . " сек<br>";
echo "memory_limit: " . ini_get('memory_limit') . "<br>";
echo "upload_max_filesize: " . ini_get('upload_max_filesize') . "<br>";
echo "Поточна директорія: " . getcwd() . "<br>";
echo "DOCUMENT_ROOT: " . ($_SERVER['DOCUMENT_ROOT'] ?? 'не встановлено') . "<br>";

echo "<br><h3>Результат тестування</h3>";
echo "Перевірте директорію: <strong>$testDir</strong><br>";
echo "Якщо файли збереглися - file_put_contents працює!<br>";
?>
