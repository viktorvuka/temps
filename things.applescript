-- Rend : projet / zone de la tâche sélectionnée, ou la liste affichée
tell application "Things3"
	set r to ""
	try
		set t to selected to dos
		if (count of t) > 0 then
			set x to item 1 of t
			try
				set r to name of project of x
			end try
			try
				if r is "" then set r to name of area of x
			end try
		end if
	end try
	return r
end tell
