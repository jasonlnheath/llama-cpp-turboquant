$body = '{"model":"qwen","messages":[{"role":"user","content":"Write a short poem about the moon."}],"max_tokens":200,"temperature":0.7}'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$resp = Invoke-RestMethod -Uri 'http://localhost:8033/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $body
$sw.Stop()
$tokens = [int]$resp.usage.completion_tokens
$elapsed = $sw.ElapsedMilliseconds / 1000
$tps = [math]::Round($tokens / $elapsed, 1)
Write-Host ("Tokens: {0} | Time: {1:N1}s | Speed: {2} tok/s" -f $tokens, $elapsed, $tps)
Write-Host $resp.choices[0].message.content
