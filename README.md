Bulk validator for Steam game integrity. Run verify.ps1 from Powershell. It will detect all Steam library locations and call the built-in steam validation tool on each game. It monitors logs from the Steam root.

If powershell script execution is disabled, run the following to temporarily bypass restrictions:
```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\verify.ps1"
```

<img width="1920" height="1011" alt="image" src="https://github.com/user-attachments/assets/134ab075-5d31-4cba-8f8c-4f95b8d67067" />
