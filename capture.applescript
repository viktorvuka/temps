-- Rend : bundle | titre de fenêtre | fichier ou URL
tell application "System Events"
	set p to first application process whose frontmost is true
	set b to bundle identifier of p
	set t to ""
	set d to ""
	try
		set w to front window of p
		set t to name of w
		set d to value of attribute "AXDocument" of w
	end try
end tell
if d is missing value then set d to ""
try
	if d is "" then
		if b is "com.apple.finder" then
			tell application "Finder" to set d to POSIX path of (target of front window as alias)
		else if b is "com.apple.Safari" then
			tell application "Safari" to set d to URL of current tab of front window
		end if
	end if
end try
return b & "|" & t & "|" & d
