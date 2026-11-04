-- Rend : compte / boîte | adresse du correspondant (expéditeur en lecture, destinataire en rédaction)
tell application "Mail"
	set lieu to ""
	set adresse to ""
	try
		set w to front window
		set enLecture to false
		repeat with v in message viewers
			if (id of window of v) is (id of w) then
				set enLecture to true
				set sel to selected messages of v
				if (count of sel) > 0 then
					set m to item 1 of sel
					set mb to mailbox of m
					set lieu to (name of account of mb) & " / " & (name of mb)
					set adresse to extract address from (sender of m)
					-- un message que l'on a soi-même envoyé : on retient le destinataire
					set miennes to {}
					repeat with c in accounts
						set miennes to miennes & (email addresses of c)
					end repeat
					if adresse is in miennes and (count of to recipients of m) > 0 then set adresse to address of item 1 of to recipients of m
				end if
				exit repeat
			end if
		end repeat
		if not enLecture then
			set lieu to "Rédaction"
			repeat with om in outgoing messages
				if (count of to recipients of om) > 0 then
					set adresse to address of item 1 of to recipients of om
				end if
			end repeat
		end if
	end try
	return lieu & "|" & adresse
end tell
