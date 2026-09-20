# claude-code-statusline

Claude Code'un alt satırına oturumun ne kadar kota ve para harcadığını yazan
tek dosyalık bir PowerShell script'i. Windows için; bağımlılığı yok, ağa hiç
çıkmaz, kendisi token harcamaz.

```
5h: 1.0% (21.9%, r:3h54m) | 7d: 8.0% (95.7%, r:0d7h) | ctx: 5% (50.0K/1.0M) | in:53.6K out:3 | cost: $0.665 | Opus 5
```

## Kurulum

Gerekenler: Windows 10 / 11 ve Claude Code. Windows PowerShell 5.1 sistemde
zaten var, PowerShell 7 de çalışır.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File kur.ps1
```

`statusline.ps1`'i `%USERPROFILE%\.claude\` altına kopyalar ve aynı klasördeki
`settings.json` içinde `statusLine` komutunu ona bağlar. Ayarların geri kalanına
dokunulmaz; yazmadan önce dosyanın `settings.json.yedek` kopyası alınır. Durum
satırı, açık Claude Code oturumları yeniden başlatılınca görünür.

Elle kurmak istersen `statusline.ps1`'i istediğin yere koy ve
`%USERPROFILE%\.claude\settings.json`'a şu alanı ekle:

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\<kullanici>\\.claude\\statusline.ps1\""
  }
}
```

Kaldırmak için:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File kur.ps1 -Kaldir
```

`statusLine` ayarı silinir; script ve biriken sayaçlar (`.claude\usage`) yerinde
kalır, onları elle silersin.

## Ne gösteriyor

| alan | ne demek |
|---|---|
| `5h: 1.0%` | 5 saatlik pencerede harcanan plan kotası |
| `(21.9%, r:3h54m)` | pencerenin ne kadarı geçti, sıfırlanmasına ne kaldı |
| `7d: 8.0% (95.7%, r:0d7h)` | aynısı 7 günlük pencere için |
| `ctx: 5% (50.0K/1.0M)` | bağlam penceresi: yüzde, dolu token / pencere boyu |
| `in:53.6K out:3` | bu oturumun baştan beri toplam girdi / çıktı tokenı |
| `cost: $0.665` | bu oturumun dolar karşılığı |
| `Opus 5` | modelin adı |

Yüzdeler %70'te sarıya, %90'da kırmızıya döner.

Parantez içindeki ikinci yüzde işin püf noktası: kota yüzdesi geçen süre
yüzdesinin belirgin altındaysa yavaş yakıyorsun, üstüne çıkıyorsa pencere
dolmadan limite çarparsın.

`cost` plandan düşen bir tutar değil, "aynı işi API'den yapsaydın ne tutardı"
demek. Claude Code'un verdiği `total_cost_usd`, her token türünün o modeldeki
birim fiyatıyla çarpımının toplamı; tek oturum içinde Opus ve Sonnet turlarını
kendi fiyatlarıyla ayrı ayrı sayıyor ve oturum başına sıfırlanıyor.

`in` / `out` neden ayrıca hesaplanıyor: Claude Code'un verdiği durum JSON'u
yalnızca o anki isteğin sayılarını taşır — `total_input_tokens` oturum toplamı
değil, anlık bağlam boyudur. Oturumun toplamı bu yüzden transcript'ten okunur.

## Nasıl çalışıyor

Claude Code her çizimde script'e stdin'den bir durum JSON'u verir, script tek
satır basar. Ağ isteği yok, API çağrısı yok: yerel dosya okuma ve aritmetik.

- **Artımlı transcript okuma.** Her çizimde bütün transcript'i okumak israf
  olurdu; script bir byte offset'i hatırlar ve yalnızca son okumadan beri eklenen
  kuyruğu ayrıştırır. Tek bir API çağrısı transcript'e birden çok satır yazar
  (içerik bloğu başına bir tane) ve hepsi aynı `usage` nesnesini taşır, üstelik
  hep art arda gelirler; aynı `requestId` tekrarı atlanarak tekilleştirilir.
  Dosya `FileShare::ReadWrite` ile açılır, yani Claude Code'un yazmasını hiç
  engellemez. Transcript kısalmışsa (baştan yazılmış demektir) sayım sıfırlanır.
- **Oturum başına bir sayaç dosyası.** `usage\<session_id>.json`; o dosyaya
  yalnızca kendi oturumu yazar, dolayısıyla aynı anda açık Claude Code
  sekmeleri birbirinin yazmasını ezmez. Yazma geçici dosya + atomik taşıma ile
  yapılır, yarım yazılmış dosya okunmaz.
- **Devam eden oturum koruması.** Bir oturum `--resume` ile sürdüğünde gelen
  maliyet sayacı sıfırdan başlayabilir; değer düştüğünde önceki tutar
  `baseCost`'a yuvarlanır, böylece toplam geri gitmez. Tokenlar transcript'ten
  yeniden hesaplandığı için onlara böyle bir koruma gerekmez.
- **Sıkıştırma.** 40'tan fazla oturum dosyası biriktiyse, 7 gündür dokunulmamış
  olanlar tek bir `archive.json`'a katlanır ve silinir — klasör aylar içinde
  sınırsız büyümesin diye. Bu iş adlandırılmış bir mutex altında yapılır, iki
  oturum aynı anda katlamaya kalkışmaz.
- **Sayı biçimi.** İş parçacığı kültürü `InvariantCulture`'a sabitlenir; yoksa
  Türkçe yerelde `53.6` yerine `53,6` yazardı.
- **Durum satırı asla kırılmaz.** Sayaç işinin tamamı `try/catch` içinde; bir
  şey ters giderse o alan çizilmez, satırın geri kalanı yine basılır.

Durum JSON'undan okunan alanlar: `session_id`, `transcript_path`,
`model.display_name`, `cost.total_cost_usd`, `context_window` ve
`rate_limits.five_hour` / `.seven_day`. Claude Code bu alanların birini
göndermezse (örneğin API anahtarıyla kullanımda plan limitleri gelmez) o parça
sessizce atlanır.

## Veriler nerede

| | |
|---|---|
| `%USERPROFILE%\.claude\usage\<session_id>.json` | oturumun sayaç durumu: offset, son `requestId`, model başına token, maliyet |
| `%USERPROFILE%\.claude\usage\archive.json` | katlanmış eski oturumların toplamı |

Script internete hiç bağlanmaz ve hiçbir şey göndermez. Transcript'ten yalnızca
`usage` sayıları alınır; konuşmanın içeriği ne okunur ne de bir yere yazılır.
Sayaçları sıfırlamak için `usage` klasörünü silmen yeterli, Claude Code bundan
etkilenmez.

## Lisans

[MIT](LICENSE).
