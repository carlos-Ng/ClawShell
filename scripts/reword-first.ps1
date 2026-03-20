$file = $args[1]
(Get-Content $file) -replace '^pick ', 'reword ' | Set-Content $file
