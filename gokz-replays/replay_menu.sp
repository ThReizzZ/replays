/*
	Replay menus.

	sm_replay -> mode menu -> category menu:
	  1. Server records (one Pro and one Nub replay per course)
	  2. Personal records (the caller's own PB per course)
	  3. All server records -> Pro/Nub -> every player's PB, sorted by time
*/

static int selectedReplayMode[MAXPLAYERS + 1];
static int selectedReplayTimeType[MAXPLAYERS + 1];



// =====[ PUBLIC ]=====

void DisplayReplayModeMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ReplayMode);
	menu.SetTitle("%T", "Replay Menu (Mode) - Title", client, gC_CurrentMap);
	AddReplayModeItems(client, menu);
	menu.Display(client, MENU_TIME_FOREVER);
}

// Adds the mode items in KZT, SKZ, VNL order (item info is the mode ID).
static void AddReplayModeItems(int client, Menu menu)
{
	int selectedMode = GOKZ_GetCoreOption(client, Option_Mode);
	int order[MODE_COUNT] = { Mode_KZTimer, Mode_SimpleKZ, Mode_Vanilla };
	char display[32], info[8];

	menu.RemoveAllItems();
	for (int i = 0; i < MODE_COUNT; i++)
	{
		int mode = order[i];

		FormatEx(display, sizeof(display), "%s", gC_ModeNames[mode]);
		if (mode == selectedMode)
		{
			Format(display, sizeof(display), "%s*", display);
		}
		FormatEx(info, sizeof(info), "%d", mode);

		if (GOKZ_GetModeLoaded(mode))
		{
			menu.AddItem(info, display, ITEMDRAW_DEFAULT);
		}
		else
		{
			menu.AddItem(info, display, ITEMDRAW_DISABLED);
		}
	}
}



// =====[ EVENTS ]=====

public int MenuHandler_ReplayMode(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(param2, info, sizeof(info));
		selectedReplayMode[param1] = StringToInt(info);
		DisplayReplayCategoryMenu(param1);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

public int MenuHandler_ReplayCategory(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(param2, info, sizeof(info));
		switch (StringToInt(info))
		{
			case 0:
			{
				DisplayServerRecordsMenu(param1);
			}
			case 1:
			{
				DisplayPersonalRecordsMenu(param1);
			}
			case 2:
			{
				DisplayAllRecordsTypeMenu(param1);
			}
		}
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_Exit && IsValidClient(param1))
		{
			DisplayReplayModeMenu(param1);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

public int MenuHandler_ServerRecords(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[48];
		menu.GetItem(param2, info, sizeof(info));
		LoadReplayFromInfo(param1, info);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_Exit && IsValidClient(param1))
		{
			DisplayReplayCategoryMenu(param1);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

public int MenuHandler_PersonalRecords(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[48];
		menu.GetItem(param2, info, sizeof(info));
		LoadReplayFromInfo(param1, info);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_Exit && IsValidClient(param1))
		{
			DisplayReplayCategoryMenu(param1);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

public int MenuHandler_AllRecordsType(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(param2, info, sizeof(info));
		selectedReplayTimeType[param1] = StringToInt(info);
		DisplayAllRecordsMenu(param1);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_Exit && IsValidClient(param1))
		{
			DisplayReplayCategoryMenu(param1);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

public int MenuHandler_AllRecords(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[48];
		menu.GetItem(param2, info, sizeof(info));
		LoadReplayFromInfo(param1, info);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_Exit && IsValidClient(param1))
		{
			DisplayAllRecordsTypeMenu(param1);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

public int SortFunc_PlayerReplayByTime(int index1, int index2, Handle array, Handle hndl)
{
	ArrayList list = view_as<ArrayList>(array);
	int block1[6], block2[6];
	list.GetArray(index1, block1);
	list.GetArray(index2, block2);

	float time1 = view_as<float>(block1[5]);
	float time2 = view_as<float>(block2[5]);
	if (time1 < time2)
	{
		return -1;
	}
	else if (time1 > time2)
	{
		return 1;
	}
	return 0;
}



// =====[ PRIVATE ]=====

static void DisplayReplayCategoryMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ReplayCategory);
	menu.SetTitle("%T", "Replay Menu - Categories - Title", client, gC_CurrentMap, gC_ModeNames[selectedReplayMode[client]]);

	char display[64];
	FormatEx(display, sizeof(display), "%T", "Replay Menu - Server Records", client);
	menu.AddItem("0", display);
	FormatEx(display, sizeof(display), "%T", "Replay Menu - Personal Records", client);
	menu.AddItem("1", display);
	FormatEx(display, sizeof(display), "%T", "Replay Menu - All Server Records", client);
	menu.AddItem("2", display);

	menu.Display(client, MENU_TIME_FOREVER);
}

static void DisplayServerRecordsMenu(int client)
{
	if (g_ReplayInfoCache == null)
	{
		GOKZ_PrintToChat(client, true, "%t", "Replay Menu - No Records");
		return;
	}

	Menu menu = new Menu(MenuHandler_ServerRecords);
	menu.SetTitle("%T", "Replay Menu - Server Records - Title", client, gC_CurrentMap, gC_ModeNames[selectedReplayMode[client]]);

	int added = 0;
	int replayInfo[RP_CACHE_BLOCKSIZE];
	char path[PLATFORM_MAX_PATH], info[48], display[192], courseLabel[16];
	for (int i = 0; i < g_ReplayInfoCache.Length; i++)
	{
		g_ReplayInfoCache.GetArray(i, replayInfo);
		if (replayInfo[1] != selectedReplayMode[client])
		{
			continue;
		}

		FormatNewServerReplayPath(path, sizeof(path), replayInfo[0], replayInfo[1], replayInfo[2], replayInfo[3]);
		if (!FileExists(path))
		{
			continue;
		}

		float time;
		char alias[MAX_NAME_LENGTH];
		if (!ReadRunReplayMeta(path, time, alias, sizeof(alias)))
		{
			continue;
		}

		GetCourseLabel(replayInfo[0], courseLabel, sizeof(courseLabel));
		FormatEx(display, sizeof(display), "%s - %s [%s %s]", alias, GOKZ_FormatTime(time), courseLabel, gC_TimeTypeNames[replayInfo[3]]);
		FormatEx(info, sizeof(info), "S;%d;%d;%d;%d", replayInfo[0], replayInfo[1], replayInfo[2], replayInfo[3]);
		menu.AddItem(info, display);
		added++;
	}

	if (added == 0)
	{
		GOKZ_PrintToChat(client, true, "%t", "Replay Menu - No Records");
		delete menu;
		return;
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

static void DisplayPersonalRecordsMenu(int client)
{
	int accountID = GetSteamAccountID(client);
	if (accountID == 0)
	{
		GOKZ_PrintToChat(client, true, "%t", "Replay Menu - No Personal Replays");
		return;
	}

	char playerDir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, playerDir, sizeof(playerDir), "%s/%s/%d", RP_DIRECTORY_NEW_PLAYERS, gC_CurrentMap, accountID);
	DirectoryListing dir = OpenDirectory(playerDir);
	if (dir == null)
	{
		GOKZ_PrintToChat(client, true, "%t", "Replay Menu - No Personal Replays");
		return;
	}

	Menu menu = new Menu(MenuHandler_PersonalRecords);
	menu.SetTitle("%T", "Replay Menu - Personal Records - Title", client, gC_CurrentMap, gC_ModeNames[selectedReplayMode[client]]);

	int added = 0;
	char fileName[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH], info[48], display[192], courseLabel[16];
	while (dir.GetNext(fileName, sizeof(fileName)))
	{
		int course, mode, style, timeType;
		if (!ParseRunReplayFileName(fileName, course, mode, style, timeType) || mode != selectedReplayMode[client])
		{
			continue;
		}

		BuildPath(Path_SM, path, sizeof(path), "%s/%s/%d/%s", RP_DIRECTORY_NEW_PLAYERS, gC_CurrentMap, accountID, fileName);
		float time;
		char alias[MAX_NAME_LENGTH];
		if (!ReadRunReplayMeta(path, time, alias, sizeof(alias)))
		{
			continue;
		}

		GetCourseLabel(course, courseLabel, sizeof(courseLabel));
		FormatEx(display, sizeof(display), "%s - %s [%s %s]", alias, GOKZ_FormatTime(time), courseLabel, gC_TimeTypeNames[timeType]);
		FormatEx(info, sizeof(info), "P;%d;%d;%d;%d", course, mode, style, timeType);
		menu.AddItem(info, display);
		added++;
	}

	delete dir;

	if (added == 0)
	{
		GOKZ_PrintToChat(client, true, "%t", "Replay Menu - No Personal Replays");
		delete menu;
		return;
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

static void DisplayAllRecordsTypeMenu(int client)
{
	Menu menu = new Menu(MenuHandler_AllRecordsType);
	menu.SetTitle("%T", "Replay Menu - All Records - Type - Title", client, gC_CurrentMap, gC_ModeNames[selectedReplayMode[client]]);

	char display[32];
	FormatEx(display, sizeof(display), "%s", gC_TimeTypeNames[TimeType_Pro]);
	menu.AddItem("1", display);
	FormatEx(display, sizeof(display), "%s", gC_TimeTypeNames[TimeType_Nub]);
	menu.AddItem("0", display);

	menu.Display(client, MENU_TIME_FOREVER);
}

static void DisplayAllRecordsMenu(int client)
{
	if (gB_PlayerReplayCacheDirty)
	{
		RebuildPlayerReplayCache();
	}

	int block[6];
	ArrayList entries = new ArrayList(6);
	for (int i = 0; i < g_PlayerReplayCache.Length; i++)
	{
		g_PlayerReplayCache.GetArray(i, block);
		if (block[1] != selectedReplayMode[client] || block[3] != selectedReplayTimeType[client])
		{
			continue;
		}
		entries.PushArray(block);
	}
	entries.SortCustom(SortFunc_PlayerReplayByTime);

	Menu menu = new Menu(MenuHandler_AllRecords);
	menu.SetTitle("%T", "Replay Menu - All Records - Title", client, gC_CurrentMap, gC_ModeNames[selectedReplayMode[client]], gC_TimeTypeNames[selectedReplayTimeType[client]]);

	int added = 0;
	char path[PLATFORM_MAX_PATH], info[48], display[192], courseLabel[16], alias[MAX_NAME_LENGTH];
	for (int i = 0; i < entries.Length; i++)
	{
		entries.GetArray(i, block);

		FormatNewPlayerReplayPath(path, sizeof(path), block[4], block[0], block[1], block[2], block[3]);
		if (!FileExists(path))
		{
			continue;
		}

		if (!g_PlayerReplayAliasCache.GetString(path, alias, sizeof(alias)))
		{
			float time;
			if (!ReadRunReplayMeta(path, time, alias, sizeof(alias)))
			{
				continue;
			}
		}

		GetCourseLabel(block[0], courseLabel, sizeof(courseLabel));
		FormatEx(display, sizeof(display), "%s - %s [%s]", alias, GOKZ_FormatTime(view_as<float>(block[5])), courseLabel);
		FormatEx(info, sizeof(info), "A;%d;%d;%d;%d;%d", block[4], block[0], block[1], block[2], block[3]);
		menu.AddItem(info, display);
		added++;
	}

	delete entries;

	if (added == 0)
	{
		GOKZ_PrintToChat(client, true, "%t", "Replay Menu - No Records");
		delete menu;
		return;
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

static bool LoadReplayFromInfo(int client, const char[] info)
{
	char pieces[6][16];
	int count = ExplodeString(info, ";", pieces, sizeof(pieces), sizeof(pieces[]));

	char path[PLATFORM_MAX_PATH];
	if (StrEqual(pieces[0], "S") && count == 5)
	{
		FormatNewServerReplayPath(path, sizeof(path), StringToInt(pieces[1]), StringToInt(pieces[2]), StringToInt(pieces[3]), StringToInt(pieces[4]));
	}
	else if (StrEqual(pieces[0], "P") && count == 5)
	{
		int accountID = GetSteamAccountID(client);
		if (accountID == 0)
		{
			return false;
		}
		FormatNewPlayerReplayPath(path, sizeof(path), accountID, StringToInt(pieces[1]), StringToInt(pieces[2]), StringToInt(pieces[3]), StringToInt(pieces[4]));
	}
	else if (StrEqual(pieces[0], "A") && count == 6)
	{
		FormatNewPlayerReplayPath(path, sizeof(path), StringToInt(pieces[1]), StringToInt(pieces[2]), StringToInt(pieces[3]), StringToInt(pieces[4]), StringToInt(pieces[5]));
	}
	else
	{
		return false;
	}

	if (!FileExists(path))
	{
		GOKZ_PrintToChat(client, true, "%t", "Replay Menu - No File");
		return false;
	}

	return LoadReplayBot(client, path) != -1;
}

void GetCourseLabel(int course, char[] buffer, int maxlength)
{
	if (course == 0)
	{
		FormatEx(buffer, maxlength, "Main");
	}
	else
	{
		FormatEx(buffer, maxlength, "B%d", course);
	}
}



