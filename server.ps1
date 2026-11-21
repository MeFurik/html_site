# ============================================================
#  Site server - PowerShell 5.1 compatible, ASCII only.
#  Data files: users.json, chat.json, stats.json, settings.json
# ============================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$script:utf8 = New-Object System.Text.UTF8Encoding($false)
$script:epochTicks = [int64]621355968000000000

function NowU {
    return [int][Math]::Floor((([DateTime]::UtcNow).Ticks - $script:epochTicks) / 10000000)
}

function LoadJson($path, $def) {
    if (-not (Test-Path $path)) { return $def }
    try { return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $def }
}

function SaveJson($obj, $path) {
    $s = ConvertTo-Json -InputObject $obj -Depth 12
    [System.IO.File]::WriteAllText($path, $s, $script:utf8)
}

function NewToken {
    $b = New-Object byte[] 24
    $r = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $r.GetBytes($b)
    return [BitConverter]::ToString($b).Replace('-', '')
}

function HashPw($login, $pw) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(('site|' + $login + '|' + $pw))
    return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
}

# ---------------- settings ----------------
$script:settingsPath = Join-Path $root 'settings.json'
if (-not (Test-Path $script:settingsPath)) {
    SaveJson (@{ siteTitle='Our site'; siteDesc='Welcome'; contacts='Phone: 000'; port=80; allowedIps=@(); adminIps=@() }) $script:settingsPath
}
function ReloadSettings {
    $raw = LoadJson $script:settingsPath $null
    if ($raw -eq $null) { $raw = @{} }
    $h = @{}
    $h['siteTitle'] = ('' + $raw.siteTitle)
    $h['siteDesc'] = ('' + $raw.siteDesc)
    $h['contacts'] = ('' + $raw.contacts)
    $p = 80
    try { $p = [int]$raw.port } catch { $p = 80 }
    if ($p -lt 1 -or $p -gt 65535) { $p = 80 }
    $h['port'] = $p
    $ips = @()
    if ($raw.allowedIps -ne $null) { $ips = @($raw.allowedIps | ForEach-Object { ('' + $_) }) }
    $h['allowedIps'] = $ips
    $ips2 = @()
    if ($raw.adminIps -ne $null) { $ips2 = @($raw.adminIps | ForEach-Object { ('' + $_) }) }
    $h['adminIps'] = $ips2
    return $h
}
$script:S = ReloadSettings

# ---------------- users ----------------
$script:usersPath = Join-Path $root 'users.json'
if (-not (Test-Path $script:usersPath)) { SaveJson @() $script:usersPath }
$script:Users = @{}
$rawUsers = LoadJson $script:usersPath @()
foreach ($u in @($rawUsers)) {
    if ($u -eq $null) { continue }
    $h = @{
        login = ('' + $u.login)
        ph = ('' + $u.ph)
        fullname = ('' + $u.fullname)
        role = ('' + $u.role)
        blocked = [bool]$u.blocked
        ip = ('' + $u.ip)
    }
    $script:Users[$h['login']] = $h
}
function SaveUsers {
    $arr = @()
    foreach ($k in $script:Users.Keys) { $arr += $script:Users[$k] }
    SaveJson @($arr) $script:usersPath
}

# ---------------- chat ----------------
$script:chatPath = Join-Path $root 'chat.json'
if (-not (Test-Path $script:chatPath)) { SaveJson @() $script:chatPath }
function ChatLoad {
    $script:Chat = @()
    foreach ($m in @(LoadJson $script:chatPath @())) {
        if ($m -eq $null) { continue }
        $h = @{
            id = [int]$m.id
            user = ('' + $m.user)
            fullname = ('' + $m.fullname)
            text = ('' + $m.text)
            to = ('' + $m.to)
            time = [int64]$m.time
        }
        $script:Chat += $h
    }
}
ChatLoad
function SaveChat { SaveJson @($script:Chat) $script:chatPath }

# ---------------- stats ----------------
$script:statsPath = Join-Path $root 'stats.json'
if (-not (Test-Path $script:statsPath)) { SaveJson @{} $script:statsPath }
$script:Stats = @()
$script:StatsMap = @{}
$rawStats = LoadJson $script:statsPath @()
if ($rawStats -ne $null) {
    foreach ($p in @($rawStats.PSObject.Properties)) {
        $script:StatsMap[$p.Name] = @{
            wins = [int]$p.Value.wins
            losses = [int]$p.Value.losses
            name = ('' + $p.Value.name)
        }
    }
}
function SaveStats {
    $h = @{}
    foreach ($k in $script:StatsMap.Keys) { $h[$k] = $script:StatsMap[$k] }
    SaveJson $h $script:statsPath
}
function BumpStat($login, $win) {
    if (-not $script:StatsMap.ContainsKey($login)) {
        $script:StatsMap[$login] = @{ wins = 0; losses = 0; name = $login }
    }
    if ($win) {
        $script:StatsMap[$login]['wins'] = [int]$script:StatsMap[$login]['wins'] + 1
    } else {
        $script:StatsMap[$login]['losses'] = [int]$script:StatsMap[$login]['losses'] + 1
    }
    if ($script:Users.ContainsKey($login)) {
        $script:StatsMap[$login]['name'] = ('' + $script:Users[$login]['fullname'])
    }
    SaveStats
}

# ---------------- runtime state ----------------
$script:Sessions = @{}
$script:chatSeen = @{}
$script:Lobby = @{}
$script:Challenges = @{}
$script:Games = @{}
$script:nextMsgId = 1
foreach ($m in $script:Chat) { if ($m['id'] -ge $script:nextMsgId) { $script:nextMsgId = $m['id'] + 1 } }

function GetAuthUser($req) {
    $tok = $req.Headers['X-Token']
    if ([string]::IsNullOrEmpty($tok)) { return $null }
    if (-not $script:Sessions.ContainsKey($tok)) { return $null }
    $s = $script:Sessions[$tok]
    if ((NowU) - [int]$s['created'] -gt 604800) {
        $script:Sessions.Remove($tok)
        return $null
    }
    if (-not $script:Users.ContainsKey([string]$s['user'])) { return $null }
    return $script:Users[[string]$s['user']]
}

function ClientIp($ctx) {
    $ip = [string]$ctx.Request.RemoteEndPoint.Address.ToString()
    if ($ip.StartsWith('::ffff:')) { $ip = $ip.Substring(7) }
    return $ip
}

function SendJson($res, $obj) {
    $s = ConvertTo-Json -InputObject $obj -Depth 12
    $b = $script:utf8.GetBytes($s)
    $res.StatusCode = 200
    $res.ContentType = 'application/json; charset=utf-8'
    $res.Headers.Add('Cache-Control', 'no-store')
    $res.ContentLength64 = $b.Length
    $res.OutputStream.Write($b, 0, $b.Length)
    $res.OutputStream.Close()
}

function ReadBody($req) {
    $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
    $t = $reader.ReadToEnd()
    $reader.Close()
    if ([string]::IsNullOrWhiteSpace($t)) { return @{} }
    try { return ($t | ConvertFrom-Json) } catch { return @{} }
}

function LastSeen($login) {
    $t = 0
    if ($script:Lobby.ContainsKey($login)) { $t = [int]$script:Lobby[$login] }
    if ($script:chatSeen.ContainsKey($login)) {
        $t2 = [int]$script:chatSeen[$login]
        if ($t2 -gt $t) { $t = $t2 }
    }
    return $t
}

# ---------------- game helpers ----------------
function FindGame($login) {
    foreach ($k in @($script:Games.Keys)) {
        $g = $script:Games[$k]
        if (([string]$g['a'] -eq $login) -or ([string]$g['b'] -eq $login)) {
            if ([string]$g['state'] -ne 'done') { return $g }
        }
    }
    return $null
}

function EndGameWithWinner($g, $winnerLogin) {
    $loser = ''
    if ([string]$g['a'] -eq $winnerLogin) { $loser = [string]$g['b'] } else { $loser = [string]$g['a'] }
    $g['state'] = 'done'
    $g['winner'] = $winnerLogin
    BumpStat $winnerLogin $true
    BumpStat $loser $false
}

function CleanGames {
    $now = NowU
    foreach ($k in @($script:Games.Keys)) {
        $g = $script:Games[$k]
        if ([string]$g['state'] -eq 'done') {
            if ($now - [int]$g['created'] -gt 600) { $script:Games.Remove($k) }
            continue
        }
        if ($now - [int]$g['created'] -gt 1800) { $script:Games.Remove($k) ; continue }
        if ([string]$g['state'] -eq 'playing') {
            $aSeen = LastSeen ([string]$g['a'])
            $bSeen = LastSeen ([string]$g['b'])
            if ($bSeen -gt 0 -and ($now - $bSeen) -gt 120) { EndGameWithWinner $g ([string]$g['a']) }
            elseif ($aSeen -gt 0 -and ($now - $aSeen) -gt 120) { EndGameWithWinner $g ([string]$g['b']) }
        }
    }
}

function ValidateCells($cells) {
    if ($cells -eq $null) { return $false }
    if (@($cells).Count -ne 100) { return $false }
    foreach ($c in $cells) {
        $n = 0
        if (-not [int]::TryParse(('' + $c), [ref]$n)) { return $false }
        if ($n -lt 0 -or $n -gt 10) { return $false }
    }
    $expected = @{1=4;2=3;3=3;4=2;5=2;6=2;7=1;8=1;9=1;10=1}
    foreach ($id in 1..10) {
        $list = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt 100; $i++) {
            if ([int]$cells[$i] -eq $id) { [void]$list.Add($i) }
        }
        if ($list.Count -ne $expected[$id]) { return $false }
        $rows = @(); $cols = @()
        foreach ($i in $list) {
            $rows += [int][Math]::Floor($i / 10)
            $cols += ($i % 10)
        }
        $sr = @($rows | Sort-Object)
        $sc = @($cols | Sort-Object)
        $contig = $true
        if ($sr[0] -eq $sr[$sr.Count - 1]) {
            for ($i = 1; $i -lt $sc.Count; $i++) { if ($sc[$i] -ne ($sc[$i - 1] + 1)) { $contig = $false } }
        } elseif ($sc[0] -eq $sc[$sc.Count - 1]) {
            for ($i = 1; $i -lt $sr.Count; $i++) { if ($sr[$i] -ne ($sr[$i - 1] + 1)) { $contig = $false } }
        } else { $contig = $false }
        if (-not $contig) { return $false }
    }
    for ($i = 0; $i -lt 100; $i++) {
        $sid = [int]$cells[$i]
        if ($sid -eq 0) { continue }
        $r = [int][Math]::Floor($i / 10); $c = ($i % 10)
        for ($dr = -1; $dr -le 1; $dr++) {
            for ($dc = -1; $dc -le 1; $dc++) {
                if ($dr -eq 0 -and $dc -eq 0) { continue }
                $nr = $r + $dr; $nc = $c + $dc
                if ($nr -ge 0 -and $nr -le 9 -and $nc -ge 0 -and $nc -le 9) {
                    $oid = [int]$cells[($nr * 10 + $nc)]
                    if ($oid -ne 0 -and $oid -ne $sid) { return $false }
                }
            }
        }
    }
    return $true
}

function ViewBoard($board, $shots, $isOwn) {
    $out = New-Object 'int[]' 100
    for ($i = 0; $i -lt 100; $i++) { $out[$i] = 0 }
    if ($isOwn) {
        for ($i = 0; $i -lt 100; $i++) { if ([int]$board[$i] -gt 0) { $out[$i] = 1 } }
    }
    foreach ($k in @($shots.Keys)) {
        $parts = $k.Split(',')
        $idx = ([int]$parts[1]) * 10 + ([int]$parts[0])
        $v = [string]$shots[$k]
        if ($v -eq 'miss') { $out[$idx] = 3 }
        elseif ($v -eq 'hit') { $out[$idx] = 2 }
        else { $out[$idx] = 4 }
    }
    foreach ($k in @($shots.Keys)) {
        if ([string]$shots[$k] -eq 'sunk') {
            $parts = $k.Split(',')
            $idx = ([int]$parts[1]) * 10 + ([int]$parts[0])
            $sid = [int]$board[$idx]
            if ($sid -gt 0) {
                for ($i = 0; $i -lt 100; $i++) {
                    if ([int]$board[$i] -eq $sid) { $out[$i] = 4 }
                }
            }
        }
    }
    return $out
}

function ShipsLeft($board, $shots) {
    $byShip = @{}
    for ($i = 0; $i -lt 100; $i++) {
        $sid = [int]$board[$i]
        if ($sid -gt 0) {
            if (-not $byShip.ContainsKey($sid)) { $byShip[$sid] = New-Object System.Collections.ArrayList }
            [void]$byShip[$sid].Add($i)
        }
    }
    $alive = 0
    foreach ($sid in @($byShip.Keys)) {
        $sunk = $true
        foreach ($i in $byShip[$sid]) {
            $key = ('' + ($i % 10)) + ',' + ('' + [int][Math]::Floor($i / 10))
            if (-not $shots.ContainsKey($key)) { $sunk = $false; break }
        }
        if (-not $sunk) { $alive++ }
    }
    return $alive
}

function GameView($g, $meLogin) {
    $h = @{}
    $h['state'] = [string]$g['state']
    $h['turn'] = [string]$g['turn']
    $h['winner'] = [string]$g['winner']
    $iAmA = ([string]$g['a'] -eq $meLogin)
    $mySide = 'A'; $enSide = 'B'
    if (-not $iAmA) { $mySide = 'B'; $enSide = 'A' }
    $myBoard = $g[('board' + $mySide)]
    $enBoard = $g[('board' + $enSide)]
    $myShotsTaken = $g[('shots' + $enSide)]
    $myShotsMade = $g[('shots' + $mySide)]
    $enLogin = ''
    if ($iAmA) { $enLogin = [string]$g['b'] } else { $enLogin = [string]$g['a'] }
    $enName = $enLogin
    if ($script:Users.ContainsKey($enLogin)) { $enName = [string]$script:Users[$enLogin]['fullname'] }
    $h['enemyLogin'] = $enLogin
    $h['enemyName'] = $enName
    $h['myBoard'] = @(ViewBoard $myBoard $myShotsTaken $true)
    $h['enemyBoard'] = @(ViewBoard $enBoard $myShotsMade $false)
    $h['myLeft'] = ShipsLeft $myBoard $myShotsTaken
    $h['enemyLeft'] = ShipsLeft $enBoard $myShotsMade
    $h['readyMe'] = [bool]$g[('ready' + $mySide)]
    $h['readyEnemy'] = [bool]$g[('ready' + $enSide)]
    return $h
}

# ---------------- API handler ----------------
function HandleApi($ctx) {
    $req = $ctx.Request
    $res = $ctx.Response
    $path = [string]$req.Url.AbsolutePath
    $b = @{}
    if ($req.HttpMethod -eq 'POST') { $b = ReadBody $req }
    $me = GetAuthUser $req
    $now = NowU

    # --- session cleanup ---
    foreach ($k in @($script:Sessions.Keys)) {
        $s = $script:Sessions[$k]
        if (($now - [int]$s['created']) -gt 604800) { $script:Sessions.Remove($k) }
    }

    # --- public site info ---
    if ($path -eq '/api/site') {
        $r = @{}
        $r['siteTitle'] = [string]$script:S['siteTitle']
        $r['siteDesc'] = [string]$script:S['siteDesc']
        $r['contacts'] = [string]$script:S['contacts']
        SendJson $res $r
        return
    }

    # --- register ---
    if ($path -eq '/api/register') {
        $login = ('' + $b.login).Trim()
        $pw = ('' + $b.password)
        $fn = ('' + $b.fullname).Trim()
        if ($login.Length -lt 3 -or $login.Length -gt 30) { SendJson $res (@{error='bad_login'}); return }
        if ($pw.Length -lt 3) { SendJson $res (@{error='bad_password'}); return }
        if ($fn.Length -lt 3) { SendJson $res (@{error='bad_fullname'}); return }
        $ip = ClientIp $ctx
        $allowed = $script:S['allowedIps']
        if (@($allowed).Count -gt 0 -and -not (@($allowed) -contains $ip)) {
            SendJson $res (@{error='ip_forbidden'}); return
        }
        $lkey = $login.ToLower()
        foreach ($k in @($script:Users.Keys)) {
            if ($k.ToLower() -eq $lkey) { SendJson $res (@{error='name_taken'}); return }
        }
        $role = 'user'
        if (@($script:S['adminIps']) -contains $ip) { $role = 'admin' }
        $u = @{ login=$login; ph=(HashPw $login $pw); fullname=$fn; role=$role; blocked=$false; ip=$ip; birth=''; unit=''; phone='' }
        $script:Users[$login] = $u
        SaveUsers
        $tok = NewToken
        $script:Sessions[$tok] = @{ user=$login; created=$now }
        Write-Host ('REGISTER: ' + $login + ' from ' + $ip + ' role=' + $role)
        SendJson $res (@{ ok=$true; token=$tok; role=$role })
        return
    }

    # --- login ---
    if ($path -eq '/api/login') {
        $login = ('' + $b.login).Trim()
        $pw = ('' + $b.password)
        $found = $null
        foreach ($k in @($script:Users.Keys)) {
            if ($k.ToLower() -eq $login.ToLower()) { $found = $script:Users[$k] }
        }
        if ($found -eq $null) { SendJson $res (@{error='no_user'}); return }
        if ([bool]$found['blocked']) { SendJson $res (@{error='blocked'}); return }
        if ([string]$found['ph'] -ne (HashPw [string]$found['login'] $pw)) {
            SendJson $res (@{error='bad_password'}); return
        }
        $tok = NewToken
        $script:Sessions[$tok] = @{ user=[string]$found['login']; created=$now }
        SendJson $res (@{ ok=$true; token=$tok })
        return
    }

    if ($path -eq '/api/logout') {
        $tok = $req.Headers['X-Token']
        if (-not [string]::IsNullOrEmpty($tok) -and $script:Sessions.ContainsKey($tok)) { $script:Sessions.Remove($tok) }
        SendJson $res (@{ok=$true})
        return
    }

    if ($path -eq '/api/me') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        $r = @{}
        $r['login'] = [string]$me['login']
        $r['fullname'] = [string]$me['fullname']
        $r['role'] = [string]$me['role']
        $r['blocked'] = [bool]$me['blocked']
        $r['ip'] = [string]$me['ip']
        $r['birth'] = [string]$me['birth']
        $r['unit'] = [string]$me['unit']
        $r['phone'] = [string]$me['phone']
        SendJson $res $r
        return
    }

    if ($path -eq '/api/profile') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ([bool]$me['blocked']) { SendJson $res (@{error='blocked'}); return }
        $fn = ('' + $b.fullname).Trim()
        if ($fn.Length -lt 3) { SendJson $res (@{error='bad_fullname'}); return }
        $me['fullname'] = $fn
        $me['birth'] = ('' + $b.birth)
        $me['unit'] = ('' + $b.unit)
        $me['phone'] = ('' + $b.phone)
        SaveUsers
        SendJson $res (@{ok=$true})
        return
    }

    # --- chat ---
    if ($path -eq '/api/chat') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ([bool]$me['blocked']) { SendJson $res (@{error='blocked'}); return }
        $vis = @()
        $isAdmin = ([string]$me['role'] -eq 'admin')
        $isMod = ([string]$me['role'] -eq 'moderator')
        foreach ($m in $script:Chat) {
            $to = [string]$m['to']
            if ($to -eq '') { $vis += $m; continue }
            if ($to -eq [string]$me['login'] -or [string]$m['user'] -eq [string]$me['login']) { $vis += $m; continue }
            if ($isAdmin -or $isMod) { $vis += $m; continue }
        }
        if ($vis.Count -gt 200) { $vis = @($vis | Select-Object -Last 200) }
        SendJson $res (@{ messages=@($vis) })
        return
    }

    if ($path -eq '/api/chat/send') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ([bool]$me['blocked']) { SendJson $res (@{error='blocked'}); return }
        $text = ('' + $b.text).Trim()
        if ($text.Length -lt 1 -or $text.Length -gt 500) { SendJson $res (@{error='bad_text'}); return }
        $to = ('' + $b.to).Trim()
        if ($to -ne '') {
            $target = $null
            foreach ($k in @($script:Users.Keys)) {
                if ($k.ToLower() -eq $to.ToLower()) { $target = $script:Users[$k] }
            }
            if ($target -eq $null) { SendJson $res (@{error='no_user'}); return }
            $to = [string]$target['login']
        }
        $m = @{
            id = $script:nextMsgId
            user = [string]$me['login']
            fullname = [string]$me['fullname']
            text = $text
            to = $to
            time = $now
        }
        $script:nextMsgId++
        $script:Chat += $m
        if ($script:Chat.Count -gt 500) { $script:Chat = @($script:Chat | Select-Object -Last 500) }
        SaveChat
        SendJson $res (@{ok=$true})
        return
    }

    if ($path -eq '/api/chat/delete') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ([bool]$me['blocked']) { SendJson $res (@{error='blocked'}); return }
        if ([string]$me['role'] -ne 'admin' -and [string]$me['role'] -ne 'moderator') {
            SendJson $res (@{error='forbidden'}); return
        }
        $id = 0
        try { $id = [int]$b.id } catch { $id = 0 }
        $newChat = @()
        $removed = $false
        foreach ($m in $script:Chat) {
            if (-not $removed -and [int]$m['id'] -eq $id) { $removed = $true; continue }
            $newChat += $m
        }
        $script:Chat = @($newChat)
        SaveChat
        SendJson $res (@{ok=$true})
        return
    }

    if ($path -eq '/api/chat/online') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ([bool]$me['blocked']) { SendJson $res (@{error='blocked'}); return }
        $script:chatSeen[[string]$me['login']] = $now
        $list = @()
        foreach ($k in @($script:chatSeen.Keys)) {
            if (($now - [int]$script:chatSeen[$k]) -gt 60) { continue }
            if (-not $script:Users.ContainsKey($k)) { continue }
            $u = $script:Users[$k]
            if ([bool]$u['blocked']) { continue }
            $list += @{ login=$k; fullname=[string]$u['fullname']; role=[string]$u['role'] }
        }
        $list = @($list | Sort-Object -Property @{Expression={$_['fullname']};Ascending=$true})
        SendJson $res (@{ online=$list })
        return
    }

    # --- games ---
    $gameRole = ([string]$me['role'] -eq 'local' -or [string]$me['role'] -eq 'moderator' -or [string]$me['role'] -eq 'admin')
    if ($path -eq '/api/games/presence') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ([bool]$me['blocked']) { SendJson $res (@{error='blocked'}); return }
        if (-not $gameRole) { SendJson $res (@{error='forbidden'}); return }
        $script:Lobby[[string]$me['login']] = $now
        CleanGames
        foreach ($k in @($script:Challenges.Keys)) {
            $c = $script:Challenges[$k]
            if (($now - [int]$c['created']) -gt 90) { $script:Challenges.Remove($k) }
        }
        foreach ($k in @($script:Lobby.Keys)) {
            if (($now - [int]$script:Lobby[$k]) -gt 20) { $script:Lobby.Remove($k) }
        }
        $incoming = $null
        foreach ($k in @($script:Challenges.Keys)) {
            $c = $script:Challenges[$k]
            if ([string]$c['to'] -eq [string]$me['login']) {
                $from = [string]$c['from']
                if ($script:Users.ContainsKey($from) -and -not [bool]$script:Users[$from]['blocked']) {
                    $incoming = @{ from=$from; name=[string]$script:Users[$from]['fullname'] }
                }
            }
        }
        $outgoing = $null
        if ($script:Challenges.ContainsKey([string]$me['login'])) {
            $c = $script:Challenges[[string]$me['login']]
            $tname = [string]$c['to']
            if ($script:Users.ContainsKey($tname)) { $tname = [string]$script:Users[$tname]['fullname'] }
            $outgoing = @{ to=[string]$c['to']; name=$tname }
        }
        $players = @()
        foreach ($k in @($script:Lobby.Keys)) {
            if (-not $script:Users.ContainsKey($k)) { continue }
            $u = $script:Users[$k]
            if ([bool]$u['blocked']) { continue }
            $status = 'free'
            if (FindGame($k)) { $status = 'busy' }
            $players += @{ login=$k; fullname=[string]$u['fullname']; role=[string]$u['role']; status=$status; isMe=($k -eq [string]$me['login']) }
        }
        $players = @($players | Sort-Object -Property @{Expression={$_['fullname']};Ascending=$true})
        $r = @{}
        $r['players'] = $players
        $r['challenge'] = $incoming
        $r['outgoing'] = $outgoing
        SendJson $res $r
        return
    }

    if ($path -eq '/api/games/challenge') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ([bool]$me['blocked']) { SendJson $res (@{error='blocked'}); return }
        if (-not $gameRole) { SendJson $res (@{error='forbidden'}); return }
        $target = ('' + $b.to)
        if ($target -eq [string]$me['login']) { SendJson $res (@{error='bad_target'}); return }
        if (-not $script:Users.ContainsKey($target)) { SendJson $res (@{error='no_user'}); return }
        if ([bool]$script:Users[$target]['blocked']) { SendJson $res (@{error='no_user'}); return }
        if (FindGame([string]$me['login'])) { SendJson $res (@{error='busy'}); return }
        if (FindGame($target)) { SendJson $res (@{error='busy_target'}); return }
        $script:Challenges[[string]$me['login']] = @{ from=[string]$me['login']; to=$target; created=$now }
        SendJson $res (@{ok=$true})
        return
    }

    if ($path -eq '/api/games/cancel') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ($script:Challenges.ContainsKey([string]$me['login'])) { $script:Challenges.Remove([string]$me['login']) }
        SendJson $res (@{ok=$true})
        return
    }

    if ($path -eq '/api/games/respond') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ([bool]$me['blocked']) { SendJson $res (@{error='blocked'}); return }
        if (-not $gameRole) { SendJson $res (@{error='forbidden'}); return }
        $acc = $false
        try { $acc = [bool]$b.accept } catch { $acc = $false }
        $foundKey = $null
        $foundCh = $null
        foreach ($k in @($script:Challenges.Keys)) {
            $c = $script:Challenges[$k]
            if ([string]$c['to'] -eq [string]$me['login']) { $foundKey = $k; $foundCh = $c }
        }
        if ($foundKey -eq $null) { SendJson $res (@{error='no_challenge'}); return }
        if (-not $acc) {
            $script:Challenges.Remove($foundKey)
            SendJson $res (@{ok=$true; declined=$true})
            return
        }
        $from = [string]$foundCh['from']
        if (-not $script:Users.ContainsKey($from)) { $script:Challenges.Remove($foundKey); SendJson $res (@{error='no_user'}); return }
        if (FindGame([string]$me['login'])) { SendJson $res (@{error='busy'}); return }
        if (FindGame($from)) { SendJson $res (@{error='busy_target'}); return }
        $la = $from; $lb = [string]$me['login']
        if ($la -gt $lb) { $tmp = $la; $la = $lb; $lb = $tmp }
        $g = @{
            a = $la; b = $lb
            boardA = $null; boardB = $null
            readyA = $false; readyB = $false
            shotsA = @{}; shotsB = @{}
            state = 'placing'; turn = ''; winner = ''
            created = $now
        }
        $script:Games[($la + '|' + $lb)] = $g
        $script:Challenges.Remove($foundKey)
        SendJson $res (@{ok=$true; started=$true})
        return
    }

    if ($path -eq '/api/games/state') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ([bool]$me['blocked']) { SendJson $res (@{error='blocked'}); return }
        if (-not $gameRole) { SendJson $res (@{error='forbidden'}); return }
        CleanGames
        $g = FindGame([string]$me['login'])
        if ($g -eq $null) { SendJson $res (@{state='none'}); return }
        $r = GameView $g [string]$me['login']
        SendJson $res $r
        return
    }

    if ($path -eq '/api/games/place') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ([bool]$me['blocked']) { SendJson $res (@{error='blocked'}); return }
        if (-not $gameRole) { SendJson $res (@{error='forbidden'}); return }
        $g = FindGame([string]$me['login'])
        if ($g -eq $null -or [string]$g['state'] -ne 'placing') { SendJson $res (@{error='no_game'}); return }
        $cells = @($b.cells | ForEach-Object { [int]$_ })
        if (-not (ValidateCells $cells)) { SendJson $res (@{error='bad_fleet'}); return }
        $iAmA = ([string]$g['a'] -eq [string]$me['login'])
        if ($iAmA) { $g['boardA'] = $cells; $g['readyA'] = $true } else { $g['boardB'] = $cells; $g['readyB'] = $true }
        if ([bool]$g['readyA'] -and [bool]$g['readyB']) {
            $t = Get-Random -Minimum 0 -Maximum 2
            if ($t -eq 0) { $g['turn'] = [string]$g['a'] } else { $g['turn'] = [string]$g['b'] }
            $g['state'] = 'playing'
            Write-Host ('GAME start: ' + $g['a'] + ' vs ' + $g['b'] + ' first=' + $g['turn'])
        }
        SendJson $res (GameView $g [string]$me['login'])
        return
    }

    if ($path -eq '/api/games/shoot') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        if ([bool]$me['blocked']) { SendJson $res (@{error='blocked'}); return }
        if (-not $gameRole) { SendJson $res (@{error='forbidden'}); return }
        $g = FindGame([string]$me['login'])
        if ($g -eq $null -or [string]$g['state'] -ne 'playing') { SendJson $res (@{error='no_game'}); return }
        if ([string]$g['turn'] -ne [string]$me['login']) { SendJson $res (@{error='not_your_turn'}); return }
        $x = [int]$b.x; $y = [int]$b.y
        if ($x -lt 0 -or $x -gt 9 -or $y -lt 0 -or $y -gt 9) { SendJson $res (@{error='bad_cell'}); return }
        $iAmA = ([string]$g['a'] -eq [string]$me['login'])
        $mySide = 'A'; $enSide = 'B'
        if (-not $iAmA) { $mySide = 'B'; $enSide = 'A' }
        $enBoard = $g[('board' + $enSide)]
        $shots = $g[('shots' + $mySide)]
        $key = ('' + $x) + ',' + ('' + $y)
        if ($shots.ContainsKey($key)) { SendJson $res (@{error='already'}); return }
        $idx = $y * 10 + $x
        $sid = [int]$enBoard[$idx]
        $result = 'miss'
        if ($sid -gt 0) {
            $allShot = $true
            for ($i = 0; $i -lt 100; $i++) {
                if ([int]$enBoard[$i] -eq $sid) {
                    $ck = ('' + ($i % 10)) + ',' + ('' + [int][Math]::Floor($i / 10))
                    if (-not $shots.ContainsKey($ck)) { $allShot = $false }
                }
            }
            if ($allShot) { $result = 'sunk' } else { $result = 'hit' }
        }
        $shots[$key] = $result
        if ($result -eq 'miss') {
            if ($iAmA) { $g['turn'] = [string]$g['b'] } else { $g['turn'] = [string]$g['a'] }
        }
        $left = ShipsLeft $enBoard $shots
        if ($result -ne 'miss' -and $left -eq 0) {
            EndGameWithWinner $g ([string]$me['login'])
        }
        $r = GameView $g [string]$me['login']
        $r['lastResult'] = $result
        SendJson $res $r
        return
    }

    if ($path -eq '/api/games/leave') {
        if ($me -eq $null) { SendJson $res (@{error='unauthorized'}); return }
        $g = FindGame([string]$me['login'])
        if ($g -ne $null) {
            if ([string]$g['state'] -eq 'playing' -and [string]$g['winner'] -eq '') {
                $other = ''
                if ([string]$g['a'] -eq [string]$me['login']) { $other = [string]$g['b'] } else { $other = [string]$g['a'] }
                EndGameWithWinner $g $other
            }
            foreach ($k in @($script:Games.Keys)) {
                if ($script:Games[$k] -eq $g) { $script:Games.Remove($k) }
            }
        }
        SendJson $res (@{ok=$true})
        return
    }

    if ($path -eq '/api/games/stats') {
        $arr = @()
        foreach ($k in @($script:StatsMap.Keys)) {
            $s = $script:StatsMap[$k]
            $arr += @{ login=$k; wins=[int]$s['wins']; losses=[int]$s['losses']; name=[string]$s['name'] }
        }
        $arr = @($arr | Sort-Object -Property @{Expression={$_['wins']};Descending=$true}, @{Expression={$_['losses']};Ascending=$true})
        SendJson $res (@{ stats=$arr })
        return
    }

    # --- admin ---
    if ($path -eq '/api/admin/users') {
        if ($me -eq $null -or [string]$me['role'] -ne 'admin') { SendJson $res (@{error='forbidden'}); return }
        $arr = @()
        foreach ($k in @($script:Users.Keys)) {
            $u = $script:Users[$k]
            $arr += @{ login=[string]$u['login']; fullname=[string]$u['fullname']; role=[string]$u['role']; blocked=[bool]$u['blocked']; ip=[string]$u['ip'] }
        }
        $arr = @($arr | Sort-Object -Property @{Expression={$_['login']};Ascending=$true})
        SendJson $res (@{ users=$arr })
        return
    }

    if ($path -eq '/api/admin/user') {
        if ($me -eq $null -or [string]$me['role'] -ne 'admin') { SendJson $res (@{error='forbidden'}); return }
        $target = ('' + $b.login)
        if (-not $script:Users.ContainsKey($target)) { SendJson $res (@{error='no_user'}); return }
        if ($target -eq [string]$me['login']) { SendJson $res (@{error='cannot_self'}); return }
        $u = $script:Users[$target]
        if ($b.PSObject.Properties['del'] -ne $null) {
            if ([bool]$b.del) {
                foreach ($k in @($script:Sessions.Keys)) {
                    if ([string]$script:Sessions[$k]['user'] -eq $target) { $script:Sessions.Remove($k) }
                }
                if ($script:Lobby.ContainsKey($target)) { $script:Lobby.Remove($target) }
                foreach ($k in @($script:Challenges.Keys)) {
                    $c = $script:Challenges[$k]
                    if ([string]$c['from'] -eq $target -or [string]$c['to'] -eq $target) { $script:Challenges.Remove($k) }
                }
                $g = FindGame($target)
                if ($g -ne $null) {
                    $other = ''
                    if ([string]$g['a'] -eq $target) { $other = [string]$g['b'] } else { $other = [string]$g['a'] }
                    EndGameWithWinner $g $other
                }
                $script:Users.Remove($target)
                SaveUsers
                SendJson $res (@{ok=$true; deleted=$true})
                return
            }
        }
        if ($b.PSObject.Properties['role'] -ne $null) {
            $nr = ('' + $b.role)
            if (@('user','local','moderator','admin') -contains $nr) { $u['role'] = $nr }
        }
        if ($b.PSObject.Properties['blocked'] -ne $null) {
            $nb = $false
            try { $nb = [bool]$b.blocked } catch { $nb = $false }
            $u['blocked'] = $nb
            if ($nb) {
                foreach ($k in @($script:Sessions.Keys)) {
                    if ([string]$script:Sessions[$k]['user'] -eq $target) { $script:Sessions.Remove($k) }
                }
                if ($script:Lobby.ContainsKey($target)) { $script:Lobby.Remove($target) }
                foreach ($k in @($script:Challenges.Keys)) {
                    $c = $script:Challenges[$k]
                    if ([string]$c['from'] -eq $target -or [string]$c['to'] -eq $target) { $script:Challenges.Remove($k) }
                }
            }
        }
        SaveUsers
        SendJson $res (@{ok=$true})
        return
    }

    if ($path -eq '/api/admin/settings') {
        if ($me -eq $null -or [string]$me['role'] -ne 'admin') { SendJson $res (@{error='forbidden'}); return }
        $r = @{}
        $r['siteTitle'] = [string]$script:S['siteTitle']
        $r['siteDesc'] = [string]$script:S['siteDesc']
        $r['contacts'] = [string]$script:S['contacts']
        $r['port'] = [int]$script:S['port']
        $r['allowedIps'] = @([string[]]$script:S['allowedIps'])
        $r['adminIps'] = @([string[]]$script:S['adminIps'])
        $r['currentIp'] = ClientIp $ctx
        SendJson $res $r
        return
    }

    if ($path -eq '/api/admin/settings/save') {
        if ($me -eq $null -or [string]$me['role'] -ne 'admin') { SendJson $res (@{error='forbidden'}); return }
        $newS = @{}
        $newS['siteTitle'] = ('' + $b.siteTitle).Trim()
        if ($newS['siteTitle'] -eq '') { $newS['siteTitle'] = 'Our site' }
        $newS['siteDesc'] = ('' + $b.siteDesc)
        $newS['contacts'] = ('' + $b.contacts)
        $p = 80
        try { $p = [int]$b.port } catch { $p = 0 }
        if ($p -lt 1 -or $p -gt 65535) { SendJson $res (@{error='bad_port'}); return }
        $newS['port'] = $p
        function ParseIps($t) {
            $list = @()
            $parts = ('' + $t) -replace "`r", '' -split "`n|,|\|"
            foreach ($s in $parts) {
                $s = $s.Trim()
                if ($s -ne '') { $list += $s }
            }
            return @($list)
        }
        $newS['allowedIps'] = ParseIps ('' + $b.allowedIpsText)
        $newS['adminIps'] = ParseIps ('' + $b.adminIpsText)
        SaveJson $newS $script:settingsPath
        $script:S = ReloadSettings
        SendJson $res (@{ok=$true; restartNeeded=($newS['port'] -ne [int]$r.port)})
        return
    }

    if ($path -eq '/api/admin/upload') {
        if ($me -eq $null -or [string]$me['role'] -ne 'admin') { SendJson $res (@{error='forbidden'}); return }
        Add-Type -AssemblyName System.Drawing
        $kind = ('' + $b.kind)
        if ($kind -ne 'hero' -and $kind -ne 'icon') { SendJson $res (@{error='bad_kind'}); return }
        $data = ('' + $b.data)
        if ($data.StartsWith('data:')) {
            $ci = $data.IndexOf(',')
            if ($ci -ge 0) { $data = $data.Substring($ci + 1) }
        }
        $bytes = $null
        try { $bytes = [Convert]::FromBase64String($data) } catch { SendJson $res (@{error='bad_image'}); return }
        if ($bytes -eq $null -or $bytes.Length -lt 100) { SendJson $res (@{error='bad_image'}); return }
        if ($bytes.Length -gt 5242880) { SendJson $res (@{error='too_big'}); return }
        $ms = New-Object System.IO.MemoryStream
        $ms.Write($bytes, 0, $bytes.Length)
        $ms.Position = 0
        $img = $null
        try { $img = [System.Drawing.Image]::FromStream($ms) } catch { $ms.Close(); SendJson $res (@{error='bad_image'}); return }
        $target = Join-Path $root 'img\hero.jpg'
        if ($kind -eq 'icon') { $target = Join-Path $root 'icon.jpg' }
        try {
            if ($img.Width -ge 1 -and $img.Height -ge 1) {
                $img.Save($target, [System.Drawing.Imaging.ImageFormat]::Jpeg)
            }
        } catch { $img.Dispose(); $ms.Close(); SendJson $res (@{error='save_failed'}); return }
        $img.Dispose()
        $ms.Close()
        SendJson $res (@{ok=$true})
        return
    }

    if ($path -eq '/api/admin/export') {
        if ($me -eq $null -or [string]$me['role'] -ne 'admin') { SendJson $res (@{error='forbidden'}); return }
        $name = ([string]$req.QueryString['name']).Trim()
        if (@('settings','users','chat','stats') -notcontains $name) { SendJson $res (@{error='bad_name'}); return }
        $fname = $name + '.json'
        $p = Join-Path $root $fname
        if (-not (Test-Path $p)) { SendJson $res (@{error='no_file'}); return }
        $content = [System.IO.File]::ReadAllBytes($p)
        $res.StatusCode = 200
        $res.ContentType = 'application/json'
        $res.Headers.Add('Content-Disposition', ('attachment; filename="' + $fname + '"'))
        $res.ContentLength64 = $content.Length
        $res.OutputStream.Write($content, 0, $content.Length)
        $res.OutputStream.Close()
        return
    }

    SendJson $res (@{error='unknown'})
}

# ---------------- static files ----------------
function HandleStatic($ctx) {
    $req = $ctx.Request
    $res = $ctx.Response
    $path = [string]$req.Url.AbsolutePath
    if ($path -eq '/') { $path = '/index.html' }
    $ext = [System.IO.Path]::GetExtension($path).ToLower()
    $allowed = @('.html', '.css', '.js', '.jpg', '.jpeg', '.png', '.gif', '.ico', '.svg', '.webp')
    if ($allowed -notcontains $ext) {
        $res.StatusCode = 404
        $b = $script:utf8.GetBytes('Not found')
        $res.ContentLength64 = $b.Length
        $res.OutputStream.Write($b, 0, $b.Length)
        $res.OutputStream.Close()
        return
    }
    $rel = $path.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $full = [System.IO.Path]::GetFullPath((Join-Path $root $rel))
    $rootFull = [System.IO.Path]::GetFullPath($root)
    if (-not $full.StartsWith($rootFull)) { $res.StatusCode = 404; $res.OutputStream.Close(); return }
    if (-not (Test-Path $full) -or (Get-Item $full).PSIsContainer) {
        $res.StatusCode = 404
        $b = $script:utf8.GetBytes('Not found')
        $res.ContentLength64 = $b.Length
        $res.OutputStream.Write($b, 0, $b.Length)
        $res.OutputStream.Close()
        return
    }
    $ctype = 'application/octet-stream'
    if ($ext -eq '.html') { $ctype = 'text/html; charset=utf-8' }
    elseif ($ext -eq '.css') { $ctype = 'text/css; charset=utf-8' }
    elseif ($ext -eq '.js') { $ctype = 'application/javascript; charset=utf-8' }
    elseif ($ext -eq '.jpg' -or $ext -eq '.jpeg') { $ctype = 'image/jpeg' }
    elseif ($ext -eq '.png') { $ctype = 'image/png' }
    elseif ($ext -eq '.gif') { $ctype = 'image/gif' }
    elseif ($ext -eq '.ico') { $ctype = 'image/x-icon' }
    elseif ($ext -eq '.svg') { $ctype = 'image/svg+xml' }
    elseif ($ext -eq '.webp') { $ctype = 'image/webp' }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $res.StatusCode = 200
    $res.ContentType = $ctype
    $res.Headers.Add('Cache-Control', 'no-store')
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

function HandleRequest($ctx) {
    try {
        $path = [string]$ctx.Request.Url.AbsolutePath
        if ($path.StartsWith('/api/')) { HandleApi $ctx }
        else { HandleStatic $ctx }
    } catch {
        Write-Host ('ERR: ' + $_.Exception.Message)
        try { SendJson $ctx.Response (@{error='server_error'}) } catch { try { $ctx.Response.OutputStream.Close() } catch {} }
    }
}

# ---------------- start listener ----------------
$port = [int]$script:S['port']
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://+:' + $port + '/')
try {
    $listener.Start()
} catch {
    Write-Host ('FAILED to bind port ' + $port + ': ' + $_.Exception.Message)
    Write-Host 'Maybe the port is busy. Change port in settings.json and run again.'
    exit 1
}
Write-Host ('Site server running on port ' + $port)
Write-Host 'Press Ctrl+C to stop. Keep this window open.'

while ($true) {
    $ctx = $listener.GetContext()
    HandleRequest $ctx
}
