-- Rend : dossier / note sélectionnée dans Notes
tell application "Notes"
	set r to ""
	try
		set n to item 1 of (get selection)
		set r to name of n
		try
			set r to (name of container of n) & " / " & r
		end try
	end try
	return r
end tell
