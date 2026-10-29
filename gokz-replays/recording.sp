/*
	Bot replay recording logic and processes.
	
	Records data every time OnPlayerRunCmdPost is called.
	If the player doesn't have their timer running, it keeps track
	of the last 2 minutes of their actions. If a player is banned
	while their timer isn't running, those 2 minutes are saved.
	If the player has their timer running, the recording is done from
	the beginning of the run. If the player can no longer beat their PB,
	then the recording goes back to only keeping track of the last
	two minutes. Upon beating their PB, a permanent replay is written to
	the player's directory with a 'header' containing information about
	the run, followed by the recorded tick data from OnPlayerRunCmdPost.
	If the run also beats the server record, another replay is written to
	the server record directory. Temporary files are only used for
	cheater/global submission.
*/

static float tickrate;
static int preAndPostRunTickCount;
static int maxCheaterReplayTicks;
static int recordingIndex[MAXPLAYERS + 1];
static float playerSensitivity[MAXPLAYERS + 1];
static float playerMYaw[MAXPLAYERS + 1];
static bool isTeleportTick[MAXPLAYERS + 1];
static int pendingTeleportTicks[MAXPLAYERS + 1];
static ReplaySaveState replaySaveState[MAXPLAYERS + 1];
static bool proPBMissed[MAXPLAYERS + 1];
static bool nubPBMissed[MAXPLAYERS + 1];
static bool recordingPaused[MAXPLAYERS + 1];
static bool postRunRecording[MAXPLAYERS + 1];
static ArrayList recordedRecentData[MAXPLAYERS + 1];
static ArrayList recordedRunData[MAXPLAYERS + 1];
static ArrayList recordedPostRunData[MAXPLAYERS + 1];
static Handle runningRunBreatherTimer[MAXPLAYERS + 1];
static ArrayList runningJumpstatTimers[MAXPLAYERS + 1];
static bool movementProcessed[MAXPLAYERS + 1];

// =====[ EVENTS ]=====

void OnMapStart_Recording()
{
	CreateReplaysDirectory(gC_CurrentMap);
	tickrate = 1/GetTickInterval();
	preAndPostRunTickCount = RoundToZero(RP_PLAYBACK_BREATHER_TIME * tickrate);
	maxCheaterReplayTicks = RoundToCeil(RP_MAX_CHEATER_REPLAY_LENGTH * tickrate);
}

void OnClientPutInServer_Recording(int client)
{
	ClearClientRecordingState(client);
}

void OnClientAuthorized_Recording(int client)
{
	// Apparently the client isn't valid yet here, so we can't check for that!
	if(!IsFakeClient(client))
	{
		// Create directory path for player if not exists
		char replayPath[PLATFORM_MAX_PATH];
		BuildPath(Path_SM, replayPath, sizeof(replayPath), "%s/%d", RP_DIRECTORY_JUMPS, GetSteamAccountID(client));
		if (!DirExists(replayPath))
		{
			CreateDirectory(replayPath, 511);
		}
		BuildPath(Path_SM, replayPath, sizeof(replayPath), "%s/%d/%s", RP_DIRECTORY_JUMPS, GetSteamAccountID(client), RP_DIRECTORY_BLOCKJUMPS);
		if (!DirExists(replayPath))
		{
			CreateDirectory(replayPath, 511);
		}
	}
}

void OnClientDisconnect_Recording(int client)
{
	// Stop exceptions if OnClientPutInServer was never ran for this client id.
	// As long as the arrays aren't null we'll be fine.
	if (runningJumpstatTimers[client] == null)
	{
		return;
	}

	// Trigger all timers early
	if(!IsFakeClient(client))
	{
		if (runningRunBreatherTimer[client] != INVALID_HANDLE)
		{
			TriggerTimer(runningRunBreatherTimer[client], false);
		}

		// We have to clone the array because the timer callback removes the timer
		// from the array we're running over, and doing weird tricks is scary.
		ArrayList timers = runningJumpstatTimers[client].Clone();
		for (int i = 0; i < timers.Length; i++)
		{
			Handle timer = timers.Get(i);
			TriggerTimer(timer, false);
		}
		delete timers;
	}

	ClearClientRecordingState(client);
}

void OnPlayerRunCmd_Recording(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client) || !IsPlayerAlive(client) || recordingPaused[client])
	{
		return;
	}
	movementProcessed[client] = false;
}

void Hook_PlayerPostThinkPost_Recording(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client) || !IsPlayerAlive(client) || recordingPaused[client])
	{
		return;
	}
	// If movement is processed, then this function will be called.
	// We don't record ticks where no movement processing happens.
	movementProcessed[client] = true;
}

void OnPlayerRunCmdPost_Recording(int client, int buttons, int tickCount, const float vel[3], const int mouse[2])
{
	if (!IsValidClient(client) || IsFakeClient(client) || !IsPlayerAlive(client) || recordingPaused[client] || !movementProcessed[client])
	{
		return;
	}

	ReplayTickData tickData;

	Movement_GetOrigin(client, tickData.origin);

	tickData.mouse = mouse;
	tickData.vel = vel;
	Movement_GetVelocity(client, tickData.velocity);
	Movement_GetEyeAngles(client, tickData.angles);
	tickData.flags = EncodePlayerFlags(client, buttons, tickCount);
	tickData.packetsPerSecond = GetClientAvgPackets(client, NetFlow_Incoming);
	tickData.laggedMovementValue = GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue");
	tickData.buttonsForced = GetEntProp(client, Prop_Data, "m_afButtonForced");

	// HACK: Reset teleport tick marker. Too bad!
	if (isTeleportTick[client])
	{
		isTeleportTick[client] = false;
	}
	if (pendingTeleportTicks[client] > 0)
	{
		pendingTeleportTicks[client]--;
	}
	
	if (replaySaveState[client] != ReplaySave_Disabled)
	{
		int runTick = GetArraySize(recordedRunData[client]);
		if (runTick < RP_MAX_DURATION)
		{
			// Resize might fail if the timer exceed the max duration,
			// as it is not guaranteed to allocate more than 1GB of contiguous memory,
			// causing mass lag spikes that kick everyone out of the server.
			// We can still attempt to save the rest of the recording though.
			recordedRunData[client].Resize(runTick + 1);
			recordedRunData[client].SetArray(runTick, tickData);
		}
	}
	if (postRunRecording[client])
	{
		int tick = GetArraySize(recordedPostRunData[client]);
		if (tick < RP_MAX_DURATION)
		{
			recordedPostRunData[client].Resize(tick + 1);
			recordedPostRunData[client].SetArray(tick, tickData);
		}
	}
	
	int tick = recordingIndex[client];
	if (recordedRecentData[client].Length < maxCheaterReplayTicks)
	{
		recordedRecentData[client].Resize(recordedRecentData[client].Length + 1);
		recordingIndex[client] = recordingIndex[client] + 1 == maxCheaterReplayTicks ? 0 : recordingIndex[client] + 1;
	}
	else
	{
		recordingIndex[client] = RecordingIndexAdd(client, 1);
	}

	recordedRecentData[client].SetArray(tick, tickData);
}

Action GOKZ_OnTimerStart_Recording(int client)
{
	// Hack to fix an exception when starting the timer on the very
	// first tick after loading the plugin.
	if (recordedRecentData[client].Length == 0)
	{
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

void GOKZ_OnTimerStart_Post_Recording(int client)
{
	replaySaveState[client] = ReplaySave_Local;
	proPBMissed[client] = false;
	nubPBMissed[client] = false;
	StartRunRecording(client);
}

void GOKZ_OnTimerEnd_Recording(int client, int course, float time, int teleportsUsed)
{
	if (replaySaveState[client] == ReplaySave_Disabled)
	{
		return;
	}

	// Decide which replays to save based on the final time type. The flags are
	// snapshotted here because a new run may start before the post-run breather
	// finishes and resets them.
	int timeType = GOKZ_GetTimeTypeEx(teleportsUsed);
	bool isServerRecord = timeType == TimeType_Pro ? !gB_ProRecordMissed[client] : !gB_NubRecordMissed[client];
	bool isPB = timeType == TimeType_Pro ? !proPBMissed[client] : !nubPBMissed[client];

	DataPack data = new DataPack();
	data.WriteCell(GetClientUserId(client));
	data.WriteCell(course);
	data.WriteFloat(time);
	data.WriteCell(teleportsUsed);
	data.WriteCell(isServerRecord);
	data.WriteCell(isPB);
	// The previous run breather still did not finish, end it now or
	// we will start overwriting the data.
	if (runningRunBreatherTimer[client] != INVALID_HANDLE)
	{
		TriggerTimer(runningRunBreatherTimer[client], false);
	}

	replaySaveState[client] = ReplaySave_Disabled;
	postRunRecording[client] = true;

	// Swap recordedRunData and recordedPostRunData.
	// This lets new runs start immediately, before the post-run breather is
	// finished recording.
	ArrayList tmp = recordedPostRunData[client];
	recordedPostRunData[client] = recordedRunData[client];
	recordedRunData[client] = tmp;
	recordedRunData[client].Clear();

	runningRunBreatherTimer[client] = CreateTimer(RP_PLAYBACK_BREATHER_TIME, Timer_EndRecording, data);
	if (runningRunBreatherTimer[client] == INVALID_HANDLE)
	{
		LogError("Could not create a timer so can't end the run replay recording");
	}
}

public Action Timer_EndRecording(Handle timer, DataPack data)
{
	data.Reset();
	int client = GetClientOfUserId(data.ReadCell());
	int course = data.ReadCell();
	float time = data.ReadFloat();
	int teleportsUsed = data.ReadCell();
	bool isServerRecord = data.ReadCell();
	bool isPB = data.ReadCell();
	delete data;

	// The client left after the run was done but before the post-run
	// breather had the chance to finish. This should not happen, as we
	// trigger all running timers on disconnect.
	if (!IsValidClient(client))
	{
		return Plugin_Stop;
	}

	runningRunBreatherTimer[client] = INVALID_HANDLE;
	postRunRecording[client] = false;

	bool isCheater = gB_GOKZLocalDB && GOKZ_DB_IsCheater(client);

	char path[PLATFORM_MAX_PATH];
	char playerPath[PLATFORM_MAX_PATH];
	bool saved = false;
	int timeType = GOKZ_GetTimeTypeEx(teleportsUsed);

	if (isCheater)
	{
		// Replay might be submitted globally, but will not be saved locally.
		saved = SaveTemporaryRecordingOfRun(path, client, course, time, teleportsUsed);
	}
	else
	{
		bool serverReplaySaved = false;
		if (isServerRecord)
		{
			serverReplaySaved = SaveServerRecordReplay(path, client, course, time, teleportsUsed);
			saved = serverReplaySaved;
		}
		bool playerReplaySaved = false;
		if (isPB)
		{
			playerReplaySaved = SavePlayerReplay(client, course, time, teleportsUsed, playerPath);
			if (playerReplaySaved && !saved)
			{
				strcopy(path, sizeof(path), playerPath);
				saved = true;
			}
		}

		// A server record also updates the player's PB replay, so only tell
		// them about the more significant one.
		if (serverReplaySaved)
		{
			PrintReplayUpdatedMessage(client, "Server Record Replay Updated", course, time, timeType);
		}
		else if (playerReplaySaved)
		{
			PrintReplayUpdatedMessage(client, "Personal Replay Updated", course, time, timeType);
		}
	}

	if (saved)
	{
		Call_OnTimerEnd_Post(client, path, course, time, teleportsUsed);
	}
	else
	{
		Call_OnTimerEnd_Post(client, "", course, time, teleportsUsed);
	}

	return Plugin_Stop;
}

void GOKZ_OnPause_Recording(int client)
{
	PauseRecording(client);
}

void GOKZ_OnResume_Recording(int client)
{
	ResumeRecording(client);
}

void GOKZ_OnTimerStopped_Recording(int client)
{
	replaySaveState[client] = ReplaySave_Disabled;
}

void GOKZ_OnCountedTeleport_Recording(int client)
{
	// The run can only end as a Nub run from now on.
	if (nubPBMissed[client] && replaySaveState[client] != ReplaySave_Disabled)
	{
		replaySaveState[client] = ReplaySave_Disabled;
	}

	if (recordingPaused[client])
	{
		pendingTeleportTicks[client]++;
	}
	else
	{
		isTeleportTick[client] = true;
	}
}

public void GOKZ_LR_OnPBMissed(int client, float pbTime, int course, int mode, int style, int recordType)
{
	if (replaySaveState[client] == ReplaySave_Disabled)
	{
		return;
	}

	if (recordType == RecordType_NubAndPro)
	{
		nubPBMissed[client] = true;
		proPBMissed[client] = true;
	}
	else if (recordType == RecordType_Nub)
	{
		nubPBMissed[client] = true;
	}
	else if (recordType == RecordType_Pro)
	{
		proPBMissed[client] = true;
	}

	// After a teleport the run can only be a Nub run, so a missed Nub PB means
	// no personal best is possible any more.
	if (GOKZ_GetTeleportCount(client) > 0 && nubPBMissed[client])
	{
		replaySaveState[client] = ReplaySave_Disabled;
		return;
	}

	// Before a teleport the run can still end as Pro or Nub, so only stop when
	// both personal bests are out of reach.
	if (nubPBMissed[client] && proPBMissed[client])
	{
		replaySaveState[client] = ReplaySave_Disabled;
	}
}

void GOKZ_AC_OnPlayerSuspected_Recording(int client, ACReason reason)
{
	SaveRecordingOfCheater(client, reason);
}

void GOKZ_DB_OnJumpstatPB_Recording(int client, int jumptype, float distance, int block, int strafes, float sync, float pre, float max, int airtime)
{
	DataPack data = new DataPack();
	data.WriteCell(GetClientUserId(client));
	data.WriteCell(jumptype);
	data.WriteFloat(distance);
	data.WriteCell(block);
	data.WriteCell(strafes);
	data.WriteFloat(sync);
	data.WriteFloat(pre);
	data.WriteFloat(max);
	data.WriteCell(airtime);

	Handle timer = CreateTimer(RP_PLAYBACK_BREATHER_TIME, SaveJump, data);
	if (timer != INVALID_HANDLE)
	{
		runningJumpstatTimers[client].Push(timer);
	}
	else
	{
		LogError("Could not create a timer so can't save jumpstat pb replay");
	}
}

public Action SaveJump(Handle timer, DataPack data)
{
	data.Reset();
	int client = GetClientOfUserId(data.ReadCell());
	int jumptype = data.ReadCell();
	float distance = data.ReadFloat();
	int block = data.ReadCell();
	int strafes = data.ReadCell();
	float sync = data.ReadFloat();
	float pre = data.ReadFloat();
	float max = data.ReadFloat();
	int airtime = data.ReadCell();
	delete data;

	// The client left after the jump was done but before the post-jump
	// breather had the chance to finish. This should not happen, as we
	// trigger all running timers on disconnect.
	if (!IsValidClient(client))
	{
		return Plugin_Stop;
	}

	RemoveFromRunningTimers(client, timer);

	SaveRecordingOfJump(client, jumptype, distance, block, strafes, sync, pre, max, airtime);
	return Plugin_Stop;
}



// =====[ PRIVATE ]=====

static void ClearClientRecordingState(int client)
{
	recordingIndex[client] = 0;
	playerSensitivity[client] = -1.0;
	playerMYaw[client] = -1.0;
	isTeleportTick[client] = false;
	pendingTeleportTicks[client] = 0;
	replaySaveState[client] = ReplaySave_Disabled;
	proPBMissed[client] = false;
	nubPBMissed[client] = false;
	recordingPaused[client] = false;
	postRunRecording[client] = false;
	runningRunBreatherTimer[client] = INVALID_HANDLE;

	if (recordedRecentData[client] == null)
		recordedRecentData[client] = new ArrayList(sizeof(ReplayTickData));

	if (recordedRunData[client] == null)
		recordedRunData[client] = new ArrayList(sizeof(ReplayTickData));

	if (recordedPostRunData[client] == null)
		recordedPostRunData[client] = new ArrayList(sizeof(ReplayTickData));

	if (runningJumpstatTimers[client] == null)
		runningJumpstatTimers[client] = new ArrayList();

	recordedRecentData[client].Clear();
	recordedRunData[client].Clear();
	recordedPostRunData[client].Clear();
	runningJumpstatTimers[client].Clear();
}

static void StartRunRecording(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	QueryClientConVar(client, "sensitivity", SensitivityCheck, client);
	QueryClientConVar(client, "m_yaw", MYAWCheck, client);
	
	DiscardRecording(client);
	ResumeRecording(client);
	
	// Copy pre data
	int index;
	recordedRunData[client].Resize(preAndPostRunTickCount);
	if (recordedRecentData[client].Length < preAndPostRunTickCount)
	{
		index = recordingIndex[client] - preAndPostRunTickCount;
	}
	else
	{
		index = RecordingIndexAdd(client, -preAndPostRunTickCount);
	}
	for (int i = 0; i < preAndPostRunTickCount; i++)
	{
		ReplayTickData tickData;
		if (index < 0)
		{
			recordedRecentData[client].GetArray(0, tickData);
			recordedRunData[client].SetArray(i, tickData);
			index += 1;
		}
		else
		{
			recordedRecentData[client].GetArray(index, tickData);
			recordedRunData[client].SetArray(i, tickData);
			index = RecordingIndexAdd(client, -preAndPostRunTickCount + i + 1);
		}
	}
}

static void DiscardRecording(int client)
{
	recordedRunData[client].Clear();
	Call_OnReplayDiscarded(client);
}

static void PauseRecording(int client)
{
	recordingPaused[client] = true;
}

static void ResumeRecording(int client)
{
	recordingPaused[client] = false;
}

static bool SaveTemporaryRecordingOfRun(char replayPath[PLATFORM_MAX_PATH], int client, int course, float time, int teleportsUsed)
{
	// Prepare data
	int timeType = GOKZ_GetTimeTypeEx(teleportsUsed);

	// Create and fill General Header
	GeneralReplayHeader generalHeader;
	FillGeneralHeader(generalHeader, client, ReplayType_Run, recordedPostRunData[client].Length);

	// Create and fill Run Header
	RunReplayHeader runHeader;
	runHeader.time = time;
	runHeader.course = course;
	runHeader.teleportsUsed = teleportsUsed;

	// Build path and create/overwrite associated file
	FormatTempReplayPath(replayPath, sizeof(replayPath), course, generalHeader.mode, generalHeader.style, timeType);
	if (FileExists(replayPath))
	{
		DeleteFile(replayPath);
	}

	File file = OpenFile(replayPath, "wb");
	if (file == null)
	{
		LogError("Failed to create/open replay file to write to: \"%s\".", replayPath);
		return false;
	}

	WriteGeneralHeader(file, generalHeader);

	// Write run header
	file.WriteInt32(view_as<int>(runHeader.time));
	file.WriteInt8(runHeader.course);
	file.WriteInt32(runHeader.teleportsUsed);

	WriteTickData(file, client, ReplayType_Run);

	delete file;
	// If there is no plugin that wants to take over the replay file, we will delete it ourselves.
	if (Call_OnReplaySaved(client, ReplayType_Run, gC_CurrentMap, course, timeType, time, replayPath, true) == Plugin_Continue)
	{
		DeleteFile(replayPath);
	}

	return true;
}

static bool WriteRunReplayFile(const char[] replayPath, int client, int course, float time, int teleportsUsed)
{
	GeneralReplayHeader generalHeader;
	FillGeneralHeader(generalHeader, client, ReplayType_Run, recordedPostRunData[client].Length);

	RunReplayHeader runHeader;
	runHeader.time = time;
	runHeader.course = course;
	runHeader.teleportsUsed = teleportsUsed;

	File file = OpenFile(replayPath, "wb");
	if (file == null)
	{
		LogError("Failed to create/open replay file to write to: \"%s\".", replayPath);
		return false;
	}

	WriteGeneralHeader(file, generalHeader);

	// Write run header
	file.WriteInt32(view_as<int>(runHeader.time));
	file.WriteInt8(runHeader.course);
	file.WriteInt32(runHeader.teleportsUsed);

	WriteTickData(file, client, ReplayType_Run);

	delete file;
	return true;
}

// Saves the server record replay for this course/mode/style/time type.
static bool SaveServerRecordReplay(char replayPath[PLATFORM_MAX_PATH], int client, int course, float time, int teleportsUsed)
{
	int timeType = GOKZ_GetTimeTypeEx(teleportsUsed);
	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	int style = GOKZ_GetCoreOption(client, Option_Style);

	FormatNewServerReplayPath(replayPath, sizeof(replayPath), course, mode, style, timeType);
	if (!IsInReplayInfoCache(course, mode, style, timeType))
	{
		AddToReplayInfoCache(course, mode, style, timeType);
		SortReplayInfoCache();
	}
	if (FileExists(replayPath))
	{
		DeleteFile(replayPath);
	}

	if (!WriteRunReplayFile(replayPath, client, course, time, teleportsUsed))
	{
		return false;
	}

	Call_OnReplaySaved(client, ReplayType_Run, gC_CurrentMap, course, timeType, time, replayPath, false);
	return true;
}

// Saves this player's fastest replay for this course/mode/style/time type.
static bool SavePlayerReplay(int client, int course, float time, int teleportsUsed, char replayPath[PLATFORM_MAX_PATH])
{
	replayPath[0] = '\0';

	int accountID = GetSteamAccountID(client);
	if (accountID == 0)
	{
		LogError("Failed to save player replay: client is not authenticated.");
		return false;
	}

	int timeType = GOKZ_GetTimeTypeEx(teleportsUsed);
	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	int style = GOKZ_GetCoreOption(client, Option_Style);

	char playerDir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, playerDir, sizeof(playerDir), "%s/%s/%d", RP_DIRECTORY_NEW_PLAYERS, gC_CurrentMap, accountID);
	if (!DirExists(playerDir))
	{
		CreateDirectory(playerDir, 511);
	}

	FormatNewPlayerReplayPath(replayPath, sizeof(replayPath), accountID, course, mode, style, timeType);
	if (FileExists(replayPath))
	{
		DeleteFile(replayPath);
	}

	if (!WriteRunReplayFile(replayPath, client, course, time, teleportsUsed))
	{
		replayPath[0] = '\0';
		return false;
	}

	MarkPlayerReplayCacheDirty();
	return true;
}

// Notifies the player that a replay file was updated. The prefix is part of
// the translation, so this plugin can use its own "(>_<)" prefix instead of
// the server-wide GOKZ chat prefix.
static void PrintReplayUpdatedMessage(int client, const char[] phrase, int course, float time, int timeType)
{
	char courseLabel[16];
	GetCourseLabel(course, courseLabel, sizeof(courseLabel));
	GOKZ_PrintToChat(client, false, "%t", phrase, GOKZ_FormatTime(time), courseLabel, gC_TimeTypeNames[timeType]);
}

static bool SaveRecordingOfCheater(int client, ACReason reason)
{
	// Create and fill general header
	GeneralReplayHeader generalHeader;
	FillGeneralHeader(generalHeader, client, ReplayType_Cheater, recordedRecentData[client].Length);

	// Create and fill cheater header
	CheaterReplayHeader cheaterHeader;
	cheaterHeader.ACReason = reason;

	//Build path and create/overwrite associated file
	char replayPath[PLATFORM_MAX_PATH];
	FormatCheaterReplayPath(replayPath, sizeof(replayPath), client, generalHeader.mode, generalHeader.style);

	File file = OpenFile(replayPath, "wb");
	if (file == null)
	{
		LogError("Failed to create/open replay file to write to: \"%s\".", replayPath);
		return false;
	}

	WriteGeneralHeader(file, generalHeader);
	file.WriteInt8(view_as<int>(cheaterHeader.ACReason));
	WriteTickData(file, client, ReplayType_Cheater);

	delete file;

	return true;
}

static bool SaveRecordingOfJump(int client, int jumptype, float distance, int block, int strafes, float sync, float pre, float max, int airtime)
{
	// Just cause I know how buggy jumpstats can be
	int airtimeTicks = RoundToNearest((float(airtime) / GOKZ_DB_JS_AIRTIME_PRECISION) * tickrate);
	if (airtimeTicks + 2 * preAndPostRunTickCount >= maxCheaterReplayTicks)
	{
		LogError("WARNING: Invalid airtime (this is probably a bugged jump, please report it!).");
		return false;
	}
	
	// Create and fill general header
	GeneralReplayHeader generalHeader;
	FillGeneralHeader(generalHeader, client, ReplayType_Jump, 2 * preAndPostRunTickCount + airtimeTicks);

	// Create and fill jump header
	JumpReplayHeader jumpHeader;
	FillJumpHeader(jumpHeader, jumptype, distance, block, strafes, sync, pre, max, airtime);

	// Make sure the client is authenticated
	if (GetSteamAccountID(client) == 0)
	{
		LogError("Failed to save jump, client is not authenticated.");
		return false;
	}

	// Build path and create/overwrite associated file
	char replayPath[PLATFORM_MAX_PATH];
	if (block > 0)
	{
		FormatBlockJumpReplayPath(replayPath, sizeof(replayPath), client, block, jumpHeader.jumpType, generalHeader.mode, generalHeader.style);
	}
	else
	{
		FormatJumpReplayPath(replayPath, sizeof(replayPath), client, jumpHeader.jumpType, generalHeader.mode, generalHeader.style);
	}

	File file = OpenFile(replayPath, "wb");
	if (file == null)
	{
		LogError("Failed to create/open replay file to write to: \"%s\".", replayPath);
		delete file;
		return false;
	}

	WriteGeneralHeader(file, generalHeader);
	WriteJumpHeader(file, jumpHeader);
	WriteTickData(file, client, ReplayType_Jump, airtimeTicks);

	delete file;

	return true;
}

static void FillGeneralHeader(GeneralReplayHeader generalHeader, int client, int replayType, int tickCount)
{
	// Prepare data
	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	int style = GOKZ_GetCoreOption(client, Option_Style);

	// Fill general header
	generalHeader.magicNumber = RP_MAGIC_NUMBER;
	generalHeader.formatVersion = RP_FORMAT_VERSION;
	generalHeader.replayType = replayType;
	generalHeader.gokzVersion = GOKZ_VERSION;
	generalHeader.mapName = gC_CurrentMap;
	generalHeader.mapFileSize = gI_CurrentMapFileSize;
	generalHeader.serverIP = FindConVar("hostip").IntValue;
	generalHeader.timestamp = GetTime();
	GetClientName(client, generalHeader.playerAlias, sizeof(GeneralReplayHeader::playerAlias));
	generalHeader.playerSteamID = GetSteamAccountID(client);
	generalHeader.mode = mode;
	generalHeader.style = style;
	generalHeader.playerSensitivity = playerSensitivity[client];
	generalHeader.playerMYaw = playerMYaw[client];
	generalHeader.tickrate = tickrate;
	generalHeader.tickCount = tickCount;
	generalHeader.equippedWeapon = GetPlayerWeaponSlotDefIndex(client, CS_SLOT_SECONDARY);
	generalHeader.equippedKnife = GetPlayerWeaponSlotDefIndex(client, CS_SLOT_KNIFE);
}

static void FillJumpHeader(JumpReplayHeader jumpHeader, int jumptype, float distance, int block, int strafes, float sync, float pre, float max, int airtime)
{
	jumpHeader.jumpType = jumptype;
	jumpHeader.distance = distance;
	jumpHeader.blockDistance = block;
	jumpHeader.strafeCount = strafes;
	jumpHeader.sync = sync;
	jumpHeader.pre = pre;
	jumpHeader.max = max;
	jumpHeader.airtime = airtime;
}

static void WriteGeneralHeader(File file, GeneralReplayHeader generalHeader)
{
	file.WriteInt32(generalHeader.magicNumber);
	file.WriteInt8(generalHeader.formatVersion);
	file.WriteInt8(generalHeader.replayType);
	file.WriteInt8(strlen(generalHeader.gokzVersion));
	file.WriteString(generalHeader.gokzVersion, false);
	file.WriteInt8(strlen(generalHeader.mapName));
	file.WriteString(generalHeader.mapName, false);
	file.WriteInt32(generalHeader.mapFileSize);
	file.WriteInt32(generalHeader.serverIP);
	file.WriteInt32(generalHeader.timestamp);
	file.WriteInt8(strlen(generalHeader.playerAlias));
	file.WriteString(generalHeader.playerAlias, false);
	file.WriteInt32(generalHeader.playerSteamID);
	file.WriteInt8(generalHeader.mode);
	file.WriteInt8(generalHeader.style);
	file.WriteInt32(view_as<int>(generalHeader.playerSensitivity));
	file.WriteInt32(view_as<int>(generalHeader.playerMYaw));
	file.WriteInt32(view_as<int>(generalHeader.tickrate));
	file.WriteInt32(generalHeader.tickCount);
	file.WriteInt32(generalHeader.equippedWeapon);
	file.WriteInt32(generalHeader.equippedKnife);
}

static void WriteJumpHeader(File file, JumpReplayHeader jumpHeader)
{
	file.WriteInt8(jumpHeader.jumpType);
	file.WriteInt32(view_as<int>(jumpHeader.distance));
	file.WriteInt32(jumpHeader.blockDistance);
	file.WriteInt8(jumpHeader.strafeCount);
	file.WriteInt32(view_as<int>(jumpHeader.sync));
	file.WriteInt32(view_as<int>(jumpHeader.pre));
	file.WriteInt32(view_as<int>(jumpHeader.max));
	file.WriteInt32((jumpHeader.airtime));
}

static void WriteTickData(File file, int client, int replayType, int airtime = 0)
{
	ReplayTickData tickData;
	ReplayTickData prevTickData;
	bool isFirstTick = true;
	switch(replayType)
	{
		case ReplayType_Run:
		{
			for (int i = 0; i < recordedPostRunData[client].Length; i++)
			{
				recordedPostRunData[client].GetArray(i, tickData);
				recordedPostRunData[client].GetArray(IntMax(0, i-1), prevTickData);
				WriteTickDataToFile(file, isFirstTick, tickData, prevTickData);
				isFirstTick = false;
			}
		}
		case ReplayType_Cheater:
		{
			for (int i = 0; i < recordedRecentData[client].Length; i++)
			{
				int rollingI = RecordingIndexAdd(client, i);
				recordedRecentData[client].GetArray(rollingI, tickData);
				recordedRecentData[client].GetArray(RecordingIndexAdd(client, IntMax(0, i-1)), prevTickData);
				WriteTickDataToFile(file, isFirstTick, tickData, prevTickData);
				isFirstTick = false;
			}
			
		}
		case ReplayType_Jump:
		{
			int replayLength = 2 * preAndPostRunTickCount + airtime;
			for (int i = 0; i < replayLength; i++)
			{
				int rollingI = RecordingIndexAdd(client, i - replayLength);
				recordedRecentData[client].GetArray(rollingI, tickData);
				recordedRecentData[client].GetArray(RecordingIndexAdd(client, IntMax(0, i-1) - replayLength), prevTickData);
				WriteTickDataToFile(file, isFirstTick, tickData, prevTickData);
				isFirstTick = false;
			}
		}
	}
}

static void WriteTickDataToFile(File file, bool isFirstTick, ReplayTickData tickDataStruct, ReplayTickData prevTickDataStruct)
{
	any tickData[RP_V2_TICK_DATA_BLOCKSIZE];
	any prevTickData[RP_V2_TICK_DATA_BLOCKSIZE];
	TickDataToArray(tickDataStruct, tickData);
	TickDataToArray(prevTickDataStruct, prevTickData);
	
	int deltaFlags = (1 << RPDELTA_DELTAFLAGS);
	if (isFirstTick)
	{
		// NOTE: Set every bit to 1 until RP_V2_TICK_DATA_BLOCKSIZE.
		deltaFlags = (1 << (RP_V2_TICK_DATA_BLOCKSIZE)) - 1;
	}
	else
	{
		// NOTE: Test tickData against prevTickData for differences.
		for (int i = 1; i < sizeof(tickData); i++)
		{
			// If the bits in tickData[i] are different to prevTickData[i], then
			// set the corresponding bitflag.
			if (tickData[i] ^ prevTickData[i])
			{
				deltaFlags |= (1 << i);
			}
		}
	}

	file.WriteInt32(deltaFlags);
	// NOTE: write only data that has changed since the previous tick.
	for (int i = 1; i < sizeof(tickData); i++)
	{
		int currentFlag = (1 << i);
		if (deltaFlags & currentFlag)
		{
			file.WriteInt32(tickData[i]);
		}
	}
}

static void FormatTempReplayPath(char[] buffer, int maxlength, int course, int mode, int style, int timeType)
{
	// Use GetEngineTime to prevent accidental replay overrides.
	// Technically it would still be possible to override this file by accident,
	// if somehow the server restarts to this exact map and course,
	// and this function is run at the exact same time, but that is extremely unlikely.
	// Also by then this file should have already been deleted.
	char tempTimeString[32];
	Format(tempTimeString, sizeof(tempTimeString), "%f_", GetEngineTime());
	BuildPath(Path_SM, buffer, maxlength,
		"%s/%s/%s%d_%s_%s_%s.%s",
		RP_DIRECTORY_NEW_TEMP,
		gC_CurrentMap,
		tempTimeString,
		course,
		gC_ModeNamesShort[mode],
		gC_StyleNamesShort[style],
		gC_TimeTypeNames[timeType],
		RP_FILE_EXTENSION);
}

void FormatNewServerReplayPath(char[] buffer, int maxlength, int course, int mode, int style, int timeType)
{
	BuildPath(Path_SM, buffer, maxlength,
		"%s/%s/%d_%s_%s_%s.%s",
		RP_DIRECTORY_NEW_SERVER,
		gC_CurrentMap,
		course,
		gC_ModeNamesShort[mode],
		gC_StyleNamesShort[style],
		gC_TimeTypeNames[timeType],
		RP_FILE_EXTENSION);
}

void FormatNewPlayerReplayPath(char[] buffer, int maxlength, int accountID, int course, int mode, int style, int timeType)
{
	BuildPath(Path_SM, buffer, maxlength,
		"%s/%s/%d/%d_%s_%s_%s.%s",
		RP_DIRECTORY_NEW_PLAYERS,
		gC_CurrentMap,
		accountID,
		course,
		gC_ModeNamesShort[mode],
		gC_StyleNamesShort[style],
		gC_TimeTypeNames[timeType],
		RP_FILE_EXTENSION);
}

static void FormatCheaterReplayPath(char[] buffer, int maxlength, int client, int mode, int style)
{
	BuildPath(Path_SM, buffer, maxlength,
		"%s/%d_%s_%d_%s_%s.%s",
		RP_DIRECTORY_CHEATERS,
		GetSteamAccountID(client),
		gC_CurrentMap,
		GetTime(),
		gC_ModeNamesShort[mode], 
		gC_StyleNamesShort[style], 
		RP_FILE_EXTENSION);
}

static void FormatJumpReplayPath(char[] buffer, int maxlength, int client, int jumpType, int mode, int style)
{
	BuildPath(Path_SM, buffer, maxlength,
		"%s/%d/%d_%s_%s.%s",
		RP_DIRECTORY_JUMPS,
		GetSteamAccountID(client),
		jumpType,
		gC_ModeNamesShort[mode],
		gC_StyleNamesShort[style],
		RP_FILE_EXTENSION);
}

static void FormatBlockJumpReplayPath(char[] buffer, int maxlength, int client, int block, int jumpType, int mode, int style)
{
	BuildPath(Path_SM, buffer, maxlength,
		"%s/%d/%s/%d_%d_%s_%s.%s",
		RP_DIRECTORY_JUMPS,
		GetSteamAccountID(client),
		RP_DIRECTORY_BLOCKJUMPS,
		jumpType,
		block,
		gC_ModeNamesShort[mode],
		gC_StyleNamesShort[style],
		RP_FILE_EXTENSION);
}

static int EncodePlayerFlags(int client, int buttons, int tickCount)
{
	int flags = 0;
	MoveType movetype = Movement_GetMovetype(client);
	int clientFlags = GetEntityFlags(client);
	
	flags = view_as<int>(movetype) & RP_MOVETYPE_MASK;

	SetKthBit(flags, 4, IsBitSet(buttons, IN_ATTACK));
	SetKthBit(flags, 5, IsBitSet(buttons, IN_ATTACK2));
	SetKthBit(flags, 6, IsBitSet(buttons, IN_JUMP));
	SetKthBit(flags, 7, IsBitSet(buttons, IN_DUCK));
	SetKthBit(flags, 8, IsBitSet(buttons, IN_FORWARD));
	SetKthBit(flags, 9, IsBitSet(buttons, IN_BACK));
	SetKthBit(flags, 10, IsBitSet(buttons, IN_LEFT));
	SetKthBit(flags, 11, IsBitSet(buttons, IN_RIGHT));
	SetKthBit(flags, 12, IsBitSet(buttons, IN_MOVELEFT));
	SetKthBit(flags, 13, IsBitSet(buttons, IN_MOVERIGHT));
	SetKthBit(flags, 14, IsBitSet(buttons, IN_RELOAD));
	SetKthBit(flags, 15, IsBitSet(buttons, IN_SPEED));
	SetKthBit(flags, 16, IsBitSet(buttons, IN_USE));
	SetKthBit(flags, 17, IsBitSet(buttons, IN_BULLRUSH));
	SetKthBit(flags, 18, IsBitSet(clientFlags, FL_ONGROUND));
	SetKthBit(flags, 19, IsBitSet(clientFlags, FL_DUCKING));
	SetKthBit(flags, 20, IsBitSet(clientFlags, FL_SWIM));

	SetKthBit(flags, 21, GetEntProp(client, Prop_Data, "m_nWaterLevel") != 0);

	SetKthBit(flags, 22, isTeleportTick[client] || pendingTeleportTicks[client] > 0);
	SetKthBit(flags, 23, Movement_GetTakeoffTick(client) == tickCount);
	SetKthBit(flags, 24, GOKZ_GetHitPerf(client));
	SetKthBit(flags, 25, IsCurrentWeaponSecondary(client));

	return flags;
}

// Function to set the bitNum bit in integer to value
static void SetKthBit(int &number, int offset, bool value)
{
	int intValue = value ? 1 : 0;
	number |= intValue << offset;
}

static bool IsBitSet(int number, int checkBit)
{
	return (number & checkBit) ? true : false;
}

static int GetPlayerWeaponSlotDefIndex(int client, int slot)
{
	int ent = GetPlayerWeaponSlot(client, slot);
	
	// Nothing equipped in the slot
	if (ent == -1)
	{
		return -1;
	}
	
	return GetEntProp(ent, Prop_Send, "m_iItemDefinitionIndex");
}

static bool IsCurrentWeaponSecondary(int client)
{
	int activeWeaponEnt = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int secondaryEnt = GetPlayerWeaponSlot(client, CS_SLOT_SECONDARY);
	return activeWeaponEnt == secondaryEnt;
}

static void CreateReplaysDirectory(const char[] map)
{
	char path[PLATFORM_MAX_PATH];

	// Create parent replay directory
	BuildPath(Path_SM, path, sizeof(path), RP_DIRECTORY);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}

	// New replay storage root
	BuildPath(Path_SM, path, sizeof(path), "%s", RP_DIRECTORY_NEW);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}

	// New replay storage: server records
	BuildPath(Path_SM, path, sizeof(path), "%s", RP_DIRECTORY_NEW_SERVER);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}
	BuildPath(Path_SM, path, sizeof(path), "%s/%s", RP_DIRECTORY_NEW_SERVER, map);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}

	// New replay storage: player personal bests
	BuildPath(Path_SM, path, sizeof(path), "%s", RP_DIRECTORY_NEW_PLAYERS);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}
	BuildPath(Path_SM, path, sizeof(path), "%s/%s", RP_DIRECTORY_NEW_PLAYERS, map);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}

	// New replay storage: temporary replays
	BuildPath(Path_SM, path, sizeof(path), "%s", RP_DIRECTORY_NEW_TEMP);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}
	BuildPath(Path_SM, path, sizeof(path), "%s/%s", RP_DIRECTORY_NEW_TEMP, map);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}

	// Create cheaters replay directory
	BuildPath(Path_SM, path, sizeof(path), "%s", RP_DIRECTORY_CHEATERS);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}

	// Create jumps parent replay directory
	BuildPath(Path_SM, path, sizeof(path), "%s", RP_DIRECTORY_JUMPS);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}
}

public void MYAWCheck(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, any value)
{
	if (IsValidClient(client) && !IsFakeClient(client))
	{
		playerMYaw[client] = StringToFloat(cvarValue);
	}
}

public void SensitivityCheck(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, any value)
{
	if (IsValidClient(client) && !IsFakeClient(client))
	{
		playerSensitivity[client] = StringToFloat(cvarValue);
	}
}

static int RecordingIndexAdd(int client, int offset)
{
	int index = recordingIndex[client] + offset;
	if (index < 0)
	{
		index += recordedRecentData[client].Length;
	}
	return index % recordedRecentData[client].Length;
}

static void RemoveFromRunningTimers(int client, Handle timerToRemove)
{
	int index = runningJumpstatTimers[client].FindValue(timerToRemove);
	if (index != -1)
	{
		runningJumpstatTimers[client].Erase(index);
	}
}
