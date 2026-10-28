/*
	Cached info about the map's available replay files.

	Server record replays are indexed by course/mode/style/time type.
	Player personal best replays are indexed by course/mode/style/time type
	and Steam account ID, and are rebuilt lazily when the "all records" menu
	is opened.
*/

ArrayList g_PlayerReplayCache;
StringMap g_PlayerReplayAliasCache;
bool gB_PlayerReplayCacheDirty = true;



// =====[ PUBLIC ]=====

// Adds a server record replay to the cache
void AddToReplayInfoCache(int course, int mode, int style, int timeType)
{
	if (g_ReplayInfoCache == null)
	{
		g_ReplayInfoCache = new ArrayList(RP_CACHE_BLOCKSIZE, 0);
	}

	int index = g_ReplayInfoCache.Length;
	g_ReplayInfoCache.Resize(index + 1);
	g_ReplayInfoCache.Set(index, course, 0);
	g_ReplayInfoCache.Set(index, mode, 1);
	g_ReplayInfoCache.Set(index, style, 2);
	g_ReplayInfoCache.Set(index, timeType, 3);
}

bool IsInReplayInfoCache(int course, int mode, int style, int timeType)
{
	if (g_ReplayInfoCache == null)
	{
		return false;
	}

	int replayInfo[RP_CACHE_BLOCKSIZE];
	for (int i = 0; i < g_ReplayInfoCache.Length; i++)
	{
		g_ReplayInfoCache.GetArray(i, replayInfo);
		if (replayInfo[0] == course && replayInfo[1] == mode && replayInfo[2] == style && replayInfo[3] == timeType)
		{
			return true;
		}
	}
	return false;
}

// Use this to sort the cache after finished adding to it
void SortReplayInfoCache()
{
	g_ReplayInfoCache.SortCustom(SortFunc_ReplayInfoCache);
}

public int SortFunc_ReplayInfoCache(int index1, int index2, Handle array, Handle hndl)
{
	// Do not expect any indexes to be 'equal'
	int replayInfo1[RP_CACHE_BLOCKSIZE], replayInfo2[RP_CACHE_BLOCKSIZE];
	g_ReplayInfoCache.GetArray(index1, replayInfo1);
	g_ReplayInfoCache.GetArray(index2, replayInfo2);

	// Compare courses - lower course number goes first
	if (replayInfo1[0] < replayInfo2[0])
	{
		return -1;
	}
	else if (replayInfo1[0] > replayInfo2[0])
	{
		return 1;
	}
	// Same course, so compare mode
	else if (replayInfo1[1] < replayInfo2[1])
	{
		return -1;
	}
	else if (replayInfo1[1] > replayInfo2[1])
	{
		return 1;
	}
	// Same course and mode, so compare style
	else if (replayInfo1[2] < replayInfo2[2])
	{
		return -1;
	}
	else if (replayInfo1[2] > replayInfo2[2])
	{
		return 1;
	}
	// Same course, mode and style so compare time type, assuming can't be identical
	else if (replayInfo1[3] == TimeType_Pro)
	{
		return 1;
	}
	return -1;
}

// Parses a run replay filename such as "0_KZT_NRM_PRO.replay".
bool ParseRunReplayFileName(const char[] file, int &course, int &mode, int &style, int &timeType)
{
	int length = strlen(file);
	int dotpos = 0;
	for (int i = 0; i < length; i++)
	{
		if (file[i] == '.')
		{
			dotpos = i;
		}
	}
	if (dotpos == 0 || !StrEqual(file[dotpos + 1], RP_FILE_EXTENSION, false))
	{
		return false;
	}

	char name[PLATFORM_MAX_PATH];
	strcopy(name, sizeof(name), file);
	name[dotpos] = '\0';

	char pieces[4][16];
	if (ExplodeString(name, "_", pieces, sizeof(pieces), sizeof(pieces[])) != sizeof(pieces))
	{
		return false;
	}

	course = StringToInt(pieces[0]);
	mode = GetModeIDFromString(pieces[1]);
	style = GetStyleIDFromString(pieces[2]);
	timeType = GetTimeTypeIDFromString(pieces[3]);
	return GOKZ_IsValidCourse(course) && mode != -1 && style != -1 && timeType != -1;
}

// Reads the general header and run header of a v2 run replay without loading
// the tick data. Used to display the player name and time in menus.
bool ReadRunReplayMeta(const char[] path, float &time, char[] alias, int aliasMax)
{
	File file = OpenFile(path, "rb");
	if (file == null)
	{
		return false;
	}

	int magicNumber;
	if (!file.ReadInt32(magicNumber) || magicNumber != RP_MAGIC_NUMBER)
	{
		delete file;
		return false;
	}

	int formatVersion;
	if (!file.ReadInt8(formatVersion) || formatVersion != RP_FORMAT_VERSION)
	{
		delete file;
		return false;
	}

	int replayType;
	if (!file.ReadInt8(replayType) || replayType != ReplayType_Run)
	{
		delete file;
		return false;
	}

	int length;
	char buffer[256];

	// GOKZ version
	if (!file.ReadInt8(length) || length < 0 || length >= sizeof(buffer))
	{
		delete file;
		return false;
	}
	file.ReadString(buffer, sizeof(buffer), length);

	// Map name
	if (!file.ReadInt8(length) || length < 0 || length >= sizeof(buffer))
	{
		delete file;
		return false;
	}
	file.ReadString(buffer, sizeof(buffer), length);

	int dummy;
	file.ReadInt32(dummy); // Map filesize
	file.ReadInt32(dummy); // Server IP
	file.ReadInt32(dummy); // Timestamp

	// Player alias
	if (!file.ReadInt8(length) || length < 0 || length >= aliasMax)
	{
		delete file;
		return false;
	}
	file.ReadString(alias, aliasMax, length);
	alias[length] = '\0';

	file.ReadInt32(dummy); // Player Steam ID
	file.ReadInt8(length); // Mode
	file.ReadInt8(length); // Style
	file.ReadInt32(dummy); // Player sensitivity
	file.ReadInt32(dummy); // Player m_yaw
	file.ReadInt32(dummy); // Tickrate
	file.ReadInt32(dummy); // Tick count
	file.ReadInt32(dummy); // Equipped weapon
	file.ReadInt32(dummy); // Equipped knife

	// Run header time
	int timeAsInt;
	if (!file.ReadInt32(timeAsInt))
	{
		delete file;
		return false;
	}
	time = view_as<float>(timeAsInt);

	delete file;
	return true;
}

void MarkPlayerReplayCacheDirty()
{
	gB_PlayerReplayCacheDirty = true;
}

void RebuildPlayerReplayCache()
{
	if (g_PlayerReplayCache == null)
	{
		g_PlayerReplayCache = new ArrayList(6);
	}
	else
	{
		g_PlayerReplayCache.Clear();
	}

	if (g_PlayerReplayAliasCache == null)
	{
		g_PlayerReplayAliasCache = new StringMap();
	}
	else
	{
		g_PlayerReplayAliasCache.Clear();
	}

	char playersRoot[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, playersRoot, sizeof(playersRoot), "%s/%s", RP_DIRECTORY_NEW_PLAYERS, gC_CurrentMap);

	DirectoryListing players = OpenDirectory(playersRoot);
	if (players != null)
	{
		char accountIDString[32];
		while (players.GetNext(accountIDString, sizeof(accountIDString)))
		{
			int accountID = StringToInt(accountIDString);
			if (accountID == 0)
			{
				continue;
			}

			char playerDir[PLATFORM_MAX_PATH];
			BuildPath(Path_SM, playerDir, sizeof(playerDir), "%s/%s/%s", RP_DIRECTORY_NEW_PLAYERS, gC_CurrentMap, accountIDString);
			if (!DirExists(playerDir))
			{
				continue;
			}

			DirectoryListing files = OpenDirectory(playerDir);
			if (files == null)
			{
				continue;
			}

			char fileName[PLATFORM_MAX_PATH];
			while (files.GetNext(fileName, sizeof(fileName)))
			{
				int course, mode, style, timeType;
				if (!ParseRunReplayFileName(fileName, course, mode, style, timeType))
				{
					continue;
				}

				char path[PLATFORM_MAX_PATH];
				BuildPath(Path_SM, path, sizeof(path), "%s/%s/%s/%s", RP_DIRECTORY_NEW_PLAYERS, gC_CurrentMap, accountIDString, fileName);

				float time;
				char alias[MAX_NAME_LENGTH];
				if (!ReadRunReplayMeta(path, time, alias, sizeof(alias)))
				{
					continue;
				}

				int index = g_PlayerReplayCache.Length;
				g_PlayerReplayCache.Resize(index + 1);
				g_PlayerReplayCache.Set(index, course, 0);
				g_PlayerReplayCache.Set(index, mode, 1);
				g_PlayerReplayCache.Set(index, style, 2);
				g_PlayerReplayCache.Set(index, timeType, 3);
				g_PlayerReplayCache.Set(index, accountID, 4);
				g_PlayerReplayCache.Set(index, view_as<int>(time), 5);
				g_PlayerReplayAliasCache.SetString(path, alias);
			}

			delete files;
		}

		delete players;
	}

	gB_PlayerReplayCacheDirty = false;
}



// =====[ EVENTS ]=====

void OnMapStart_ReplayCache()
{
	if (g_ReplayInfoCache == null)
	{
		g_ReplayInfoCache = new ArrayList(RP_CACHE_BLOCKSIZE, 0);
	}
	else
	{
		g_ReplayInfoCache.Clear();
	}

	// Player personal bests are indexed lazily on first use.
	gB_PlayerReplayCacheDirty = true;

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "%s/%s", RP_DIRECTORY_NEW_SERVER, gC_CurrentMap);
	DirectoryListing dir = OpenDirectory(path);
	if (dir == null)
	{
		return;
	}

	char file[PLATFORM_MAX_PATH];
	int course, mode, style, timeType;
	while (dir.GetNext(file, sizeof(file)))
	{
		if (!ParseRunReplayFileName(file, course, mode, style, timeType))
		{
			continue;
		}

		AddToReplayInfoCache(course, mode, style, timeType);
	}

	SortReplayInfoCache();
	delete dir;
}



// =====[ PRIVATE ]=====

static int GetModeIDFromString(const char[] mode)
{
	for (int modeID = 0; modeID < MODE_COUNT; modeID++)
	{
		if (StrEqual(mode, gC_ModeNamesShort[modeID], false))
		{
			return modeID;
		}
	}
	return -1;
}

static int GetStyleIDFromString(const char[] style)
{
	for (int styleID = 0; styleID < STYLE_COUNT; styleID++)
	{
		if (StrEqual(style, gC_StyleNamesShort[styleID], false))
		{
			return styleID;
		}
	}
	return -1;
}

static int GetTimeTypeIDFromString(const char[] timeType)
{
	for (int timeTypeID = 0; timeTypeID < TIMETYPE_COUNT; timeTypeID++)
	{
		if (StrEqual(timeType, gC_TimeTypeNames[timeTypeID], false))
		{
			return timeTypeID;
		}
	}
	return -1;
}
