@echo off
cd /d "%~dp0.."
echo Fixing commit message to remove Made-with: Cursor...

git reset --soft HEAD~1
git commit -F new-msg.txt

if %ERRORLEVEL% equ 0 (
    echo Done. Commit message updated.
    echo Run: git push --force origin add/mit-license
) else (
    echo Failed. Try running in Windows Terminal or CMD outside of Cursor.
)
pause
