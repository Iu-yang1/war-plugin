#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <multicolors>

#pragma semicolon 1

public Plugin myinfo = {
    name = "WarPlugin",
    author = "iu_yang1",
    description = "A SourceMod plugin for CS:S competition.",
    version = "v0.1",
    url = "https://github.com/Iu-yang1/war-plugin"
}

#define _DEBUG
#define PLAYER_REQUIRED 10

enum MatchStatus {
    Status_WarmUP = 0,
    Status_Started,
    Status_FirstHalf,
    Status_SecondHalf,
    Status_OverTime_FirstHalf,
    Status_OverTime_SecondHalf,
    Status_End
}

enum struct MatchInfo {
    MatchStatus Status;
    int CurrentRound;
    int CurrentRound_Overtime;
    int OvertimeCount;
    StringMap MatchPlayers;
}

enum struct PlayerData {
    bool isReady;
}

enum struct TimerData {
    Handle StartMatchCountdown;
    Handle ClearMapWeapons;
    StringMap PlayerDropedWeapon;
    Handle WarmUpNotice;
}

MatchInfo g_Match;
PlayerData g_Client[MAXPLAYERS + 1];
TimerData g_Timer;
ArrayList g_aRTVPlugins;

public void OnPluginStart() {
    g_Match.MatchPlayers = new StringMap();
    g_Timer.PlayerDropedWeapon = new StringMap();

    // 阻止危险命令
    AddCommandListener(BlockCommands, "kill");
    AddCommandListener(BlockCommands, "killvector");
    AddCommandListener(BlockCommands, "explode");
    AddCommandListener(BlockCommands, "explodevector");
    AddCommandListener(BlockCommands, "spectate");

    AddCommandListener(HookJoinTeam, "jointeam");
    AddCommandListener(HookJoinClass, "joinclass");

    // 注册命令
    RegConsoleCmd("sm_r", Ready, "准备");
    RegConsoleCmd("sm_ready", Ready, "准备");
    RegConsoleCmd("sm_un", UnReady, "取消准备");
    RegConsoleCmd("sm_unready", UnReady, "取消准备");

    RegAdminCmd("sm_start", ForceStartMatch, ADMFLAG_BAN, "强制开始比赛");
    RegAdminCmd("sm_end", ForceEndMatch, ADMFLAG_BAN, "强制结束比赛");

    #if defined _DEBUG
    RegConsoleCmd("gotoround", GotoRound, "调试用-跳转到指定回合");
    #endif

    // 事件挂钩
    HookEvent("round_start", Event_RountStart_Post);
    HookEvent("round_end", Event_RountEnd_Post);
    HookEvent("player_death", Event_PlayerDeath_Post);
    
    // 初始化
    g_aRTVPlugins = new ArrayList(64);
}

public void OnConfigsExecuted() {
    ServerCommand("mp_c4timer 40");
    ServerCommand("mp_maxrounds 0");
    ServerCommand("mp_autoteambalance 0");
    ServerCommand("mp_limitteams 0");
    ServerCommand("mp_teams_unbalance_limit 0");
    ServerCommand("mp_flashlight 1");
    ServerCommand("mp_tkpunish 0");
    ServerCommand("mp_autokick 0");
    ServerCommand("mp_spawnprotectiontime 0");
    ServerCommand("mp_hostagepenalty 0");
    ServerCommand("bot_quota 0");
    ServerCommand("bot_kick");
    InitWarmUP(INVALID_HANDLE);
}

public void OnPluginEnd() {
    delete g_Match.MatchPlayers;
    delete g_Timer.PlayerDropedWeapon;
    delete g_aRTVPlugins;
}

public void OnAllPluginsLoaded() {
    char FileName[64];
    Handle iter = GetPluginIterator();
    while (MorePlugins(iter)) {
        Handle plugin = ReadPlugin(iter);
        GetPluginFilename(plugin, FileName, sizeof(FileName));
        if (StrContains(FileName, "rockthevote", false) != -1) {
            g_aRTVPlugins.PushString(FileName);
        }
    }
    delete iter;
}

public Action ForceStartMatch(int client, int args) {
    if (g_Match.Status != Status_WarmUP) {
        CPrintToChat(client, "{olive}[CSS] {default}当前比赛已经开始！");
        return Plugin_Handled;
    }
    InitMatch();
    g_Timer.StartMatchCountdown = CreateTimer(2.0, StartMatchCountdown, 5, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(0.1, ForceStartMatchMsg, client, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Handled;
}

public Action ForceStartMatchMsg(Handle Timer, any data) {
    int client = view_as<int>(data);
    char szName[32];
    GetClientName(client, szName, sizeof(szName));
    CPrintToChatAll("{olive}[CSS] {default}管理员 {green}%s {default}强制开始了比赛！", szName);
    return Plugin_Continue;
}

public Action ForceEndMatch(int client, int args) {
    if (g_Match.Status == Status_WarmUP) {
        CPrintToChat(client, "{olive}[CSS] {default}当前比赛未开始！");
        return Plugin_Handled;
    }
    InitWarmUP(INVALID_HANDLE);
    CreateTimer(0.1, ForceEndMatchMsg, client, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Handled;
}

public Action ForceEndMatchMsg(Handle Timer, any data) {
    int client = view_as<int>(data);
    char szName[32];
    GetClientName(client, szName, sizeof(szName));
    CPrintToChatAll("{olive}[CSS] {default}管理员 {green}%s {default}强制结束了比赛！", szName);
    return Plugin_Continue;
}

public Action BlockCommands(int client, const char[] command, int argc) {
    return Plugin_Handled;
}

public Action HookJoinTeam(int client, const char[] command, int argc) {
    int ChoiseTeam = GetCmdArgInt(1);
    if (g_Match.Status == Status_WarmUP)
        return Plugin_Continue;
    if (ChoiseTeam == CS_TEAM_NONE)
        return Plugin_Handled;

    if (GetClientTeam(client) == CS_TEAM_SPECTATOR || GetClientTeam(client) == CS_TEAM_NONE) {
        char szSteamID[32];
        GetClientAuthId(client, AuthId_Steam3, szSteamID, sizeof(szSteamID));
        
        if (g_Match.MatchPlayers.ContainsKey(szSteamID)) {
            int Team;
            g_Match.MatchPlayers.GetValue(szSteamID, Team);
            if (ChoiseTeam != Team) {
                PrintCenterText(client, "无法选择此队伍！");
                return Plugin_Handled;
            }
            return Plugin_Continue;
        }
        
        // 处理新玩家加入
        int matchingCount = GetMatchingPlayerCount();
        StringMapSnapshot snapshot = g_Match.MatchPlayers.Snapshot();
        
        if (matchingCount >= snapshot.Length) {
            PrintCenterText(client, "您只能加入观察者！");
            delete snapshot;
            return Plugin_Handled;
        }
        
        StringMap unMatchingPlayers = GetUnMatchingPlayersStringMap();
        snapshot = unMatchingPlayers.Snapshot();
        int Team;
        bool found = false;
        
        for (int i = 0; i < snapshot.Length; i++) {
            char key[32];
            snapshot.GetKey(i, key, sizeof(key));
            unMatchingPlayers.GetValue(key, Team);
            
            if (Team == ChoiseTeam) {
                g_Match.MatchPlayers.Remove(key);
                GetClientAuthId(client, AuthId_Steam3, szSteamID, sizeof(szSteamID));
                g_Match.MatchPlayers.SetValue(szSteamID, ChoiseTeam);
                found = true;
                break;
            }
        }
        
        delete snapshot;
        delete unMatchingPlayers;
        
        if (!found) {
            PrintCenterText(client, "您只能加入观察者！");
            return Plugin_Handled;
        }
    }
    return Plugin_Continue;
}

public Action HookJoinClass(int client, const char[] command, int argc) {
    if (g_Match.Status == Status_WarmUP) {
        RequestFrame(RespawnPlayer, client);
        return Plugin_Continue;
    }

    if (IsPlayerAlive(client))
        return Plugin_Handled;
    return Plugin_Continue;
}

public Action StartMatchCountdown(Handle timer, any data) {
    int seconds = view_as<int>(data);
    if (seconds <= 0) {
        ServerCommand("mp_restartgame 1");
    } else {
        CPrintToChatAll("{olive}[CSS] {default}全部玩家已准备完毕！比赛将在 {green}%d {default}秒后开始！", seconds);
        g_Timer.StartMatchCountdown = CreateTimer(1.0, StartMatchCountdown, --seconds, TIMER_FLAG_NO_MAPCHANGE);
    }
    return Plugin_Continue;
}

public void Event_RountStart_Post(Event event, const char[] name, bool dontBroadcast) {
    if (g_Match.Status == Status_WarmUP || g_Match.Status == Status_End)
        return;

    g_Match.CurrentRound++;
    
    if (g_Match.Status == Status_SecondHalf) {
        if (CS_GetTeamScore(CS_TEAM_CT) >= 16) {
            MatchWin(CS_TEAM_CT);
        } else if (CS_GetTeamScore(CS_TEAM_T) >= 16) {
            MatchWin(CS_TEAM_T);
        }
    } else if (g_Match.Status >= Status_OverTime_FirstHalf) {
        g_Match.CurrentRound_Overtime++;
        if (CS_GetTeamScore(CS_TEAM_CT) > CS_GetTeamScore(CS_TEAM_T) && 
            CS_GetTeamScore(CS_TEAM_CT) - CS_GetTeamScore(CS_TEAM_T) >= 4) {
            MatchWin(CS_TEAM_CT);
        } else if (CS_GetTeamScore(CS_TEAM_T) > CS_GetTeamScore(CS_TEAM_CT) && 
                   CS_GetTeamScore(CS_TEAM_T) - CS_GetTeamScore(CS_TEAM_CT) >= 4) {
            MatchWin(CS_TEAM_T);
        }
    }

    if (g_Match.Status == Status_End)
        return;

    if (g_Match.Status >= Status_FirstHalf && g_Match.Status <= Status_SecondHalf) {
        if (CS_GetTeamScore(CS_TEAM_CT) == 15 || CS_GetTeamScore(CS_TEAM_T) == 15)
            CPrintToChatAll("{lime}---------- 赛点 ！ ----------");
    } else if (g_Match.Status >= Status_OverTime_FirstHalf) {
        int diffCT = CS_GetTeamScore(CS_TEAM_CT) - CS_GetTeamScore(CS_TEAM_T);
        int diffT = CS_GetTeamScore(CS_TEAM_T) - CS_GetTeamScore(CS_TEAM_CT);
        
        if (diffCT == 3 || diffT == 3)
            CPrintToChatAll("{lime}---------- 赛点 ！ ----------");
    }
    
    if (g_Match.Status == Status_Started) {
        CPrintToChatAll("{olive}[CSS] {lime}比赛开始！GL&HF！");
        CPrintToChatAll("{olive}[CSS] {lime}当前正在进行上半场比赛。");
        g_Match.Status = Status_FirstHalf;
        InitPlayers();
    } else if (g_Match.CurrentRound == 15) {
        CPrintToChatAll("{olive}[CSS] {lime}当前正在进行下半场比赛。");
        InitPlayers();
    } else if (g_Match.CurrentRound_Overtime == 1) {
        CPrintToChatAll("{olive}[CSS] {lime}当前正在进行加时赛 %d 上半场。", g_Match.OvertimeCount);
        InitPlayers();
    } else if (g_Match.CurrentRound_Overtime == 4) {
        CPrintToChatAll("{olive}[CSS] {lime}当前正在进行加时赛 %d 下半场。", g_Match.OvertimeCount);
        InitPlayers();
    } else {
        PrintMoneyStatus();
    }
}

public void MatchWin(int team) {
    if (team != CS_TEAM_CT && team != CS_TEAM_T)
        return;

    g_Match.Status = Status_End;
    CPrintToChatAll("{olive}[CSS] {lime}T %d:%d CT", CS_GetTeamScore(CS_TEAM_T), CS_GetTeamScore(CS_TEAM_CT));
    CPrintToChatAll("{olive}[CSS] {lime}比赛结束！%s 方获得比赛胜利！", team == CS_TEAM_CT ? "CT" : "T");
    CreateTimer(15.0, InitWarmUP, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_RountEnd_Post(Event event, const char[] name, bool dontBroadcast) {
    if (g_Match.Status == Status_WarmUP || g_Match.Status == Status_End)
        return;

    switch (g_Match.Status) {
        case Status_FirstHalf: {
            if (g_Match.CurrentRound == 14) {
                SwapTeam();
                CPrintToChatAll("{olive}[CSS] {lime}上半场比赛结束！");
                g_Match.Status = Status_SecondHalf;
            }
        }
        case Status_SecondHalf: {
            if (g_Match.CurrentRound == 29 && CS_GetTeamScore(CS_TEAM_CT) == CS_GetTeamScore(CS_TEAM_T)) {
                SwapTeam();
                g_Match.Status = Status_OverTime_FirstHalf;
                g_Match.OvertimeCount = 1;
                g_Match.CurrentRound_Overtime = 0;
                CPrintToChatAll("{olive}[CSS] {lime}双方平局！进入加时赛！");
            }
        }
        case Status_OverTime_FirstHalf: {
            if (g_Match.CurrentRound_Overtime == 3) {
                SwapTeam();
                CPrintToChatAll("{olive}[CSS] {lime}加时赛 %d 上半场结束！", g_Match.OvertimeCount);
                g_Match.Status = Status_OverTime_SecondHalf;
            }
        }
        case Status_OverTime_SecondHalf: {
            if (g_Match.CurrentRound_Overtime == 6 && CS_GetTeamScore(CS_TEAM_CT) == CS_GetTeamScore(CS_TEAM_T)) {
                SwapTeam();
                CPrintToChatAll("{olive}[CSS] {lime}加时赛 %d 平局！", g_Match.OvertimeCount);
                g_Match.Status = Status_OverTime_FirstHalf;
                g_Match.OvertimeCount++;
                g_Match.CurrentRound_Overtime = 0;
            }
        }
    }
}

public void Event_PlayerDeath_Post(Event event, const char[] name, bool dontBroadcast) {
    if (g_Match.Status >= Status_Started) return;
    int userid = GetEventInt(event, "userid");
    int client = GetClientOfUserId(userid);
    if (!client) return;
    RequestFrame(RespawnPlayer, client);
}

public void RespawnPlayer(any data) {
    int client = view_as<int>(data);
    CS_RespawnPlayer(client);
    SetEntProp(client, Prop_Send, "m_iAccount", 16000);
}

public Action Ready(int client, int args) {
    if (g_Match.Status >= Status_Started) {
        CPrintToChat(client, "{olive}[CSS] {red}当前比赛已经开始！");
        return Plugin_Handled;
    }
    if (g_Client[client].isReady) {
        CPrintToChat(client, "{olive}[CSS] {default}你已经准备了！如需取消准备，在聊天框输入 {green}!unready{red}。");
        return Plugin_Handled;
    }
    g_Client[client].isReady = true;

    int UnReadyCount = GetUnReadyCount();
    if (!UnReadyCount) {
        if (GetClientCount() < PLAYER_REQUIRED) {
            CPrintToChat(client, "{olive}[CSS] {default}你已准备！但还需要 {red}%d {default}人才能开始比赛！", PLAYER_REQUIRED - GetClientCount());
        } else {
            if (g_Timer.StartMatchCountdown != null) {
                delete g_Timer.StartMatchCountdown;
            }
            InitMatch();
            g_Timer.StartMatchCountdown = CreateTimer(2.0, StartMatchCountdown, 5, TIMER_FLAG_NO_MAPCHANGE);
        }
    } else {
        char name[32];
        GetClientName(client, name, sizeof(name));
        CPrintToChatAll("{olive}[CSS] {default}%s 已准备，还有 {red}%d {default}人未准备。在聊天框输入 {green}!r {default}进行准备！", name, UnReadyCount);
    }
    return Plugin_Handled;
}

public Action UnReady(int client, int args) {
    if (g_Match.Status >= Status_Started) {
        CPrintToChat(client, "{olive}[CSS] {red}当前比赛已经开始！");
        return Plugin_Handled;
    }
    if (g_Client[client].isReady) {
        CPrintToChat(client, "{olive}[CSS] {default}你取消了准备。");
        g_Client[client].isReady = false;
    } else {
        CPrintToChat(client, "{olive}[CSS] {default}你尚未准备！");
    }
    return Plugin_Handled;
}

public void InitMatch() {
    SetServerDescription("比赛已开始");
    g_Match.Status = Status_Started;

    InitMatchData();
    LoadMatchConfig();
    AddPlayersToMatchList();

    if (g_Timer.ClearMapWeapons != null) {
        delete g_Timer.ClearMapWeapons;
    }
    if (g_Timer.WarmUpNotice != null) {
        delete g_Timer.WarmUpNotice;
    }
    
    for(int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            CS_RespawnPlayer(i);
        }
    }
}

public Action InitWarmUP(Handle timer) {
    g_Match.Status = Status_WarmUP;
    SetServerDescription("等待比赛中");
    InitMatchData();
    LoadWarmUPConfig();
    
    if (g_Timer.StartMatchCountdown != null) {
        delete g_Timer.StartMatchCountdown;
    }
    
    if (g_Timer.ClearMapWeapons == null) {
        g_Timer.ClearMapWeapons = CreateTimer(5.0, ClearWeaponsItemsOnMap, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
    
    if (g_Timer.WarmUpNotice == null) {
        g_Timer.WarmUpNotice = CreateTimer(10.0, NoticePlayersUnready, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
    
    for(int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            InitClientData(i);
        }
    }
    ServerCommand("mp_restartgame 1");
    return Plugin_Continue;
}

void SetServerDescription(const char[] desc) {
    ServerCommand("hostdesc \"%s\"", desc);
}

public void LoadMatchConfig() {
    SetRockthevotePlugins(false);
    ServerCommand("mp_startmoney 800");
    ServerCommand("mp_freezetime 15");
    ServerCommand("mp_roundtime 1.75");
    ServerCommand("mp_forcecamera 1");
    ServerCommand("mp_buytime 0.416");
    ServerCommand("mp_friendlyfire 1");
    ServerCommand("sv_cheats 1");
    ServerCommand("mp_round_restart_delay 3.0");
}

public void LoadWarmUPConfig() {
    SetRockthevotePlugins(true);
    ServerCommand("mp_startmoney 16000");
    ServerCommand("mp_freezetime 0");
    ServerCommand("mp_roundtime 9999");
    ServerCommand("mp_forcecamera 1");
    ServerCommand("mp_buytime 9999999999");
    ServerCommand("mp_friendlyfire 0");
    ServerCommand("sv_alltalk 0");
    ServerCommand("mp_round_restart_delay 3.0");
}

public void SetRockthevotePlugins(bool Load) {
    char Buffer[64];
    for (int i = 0; i < g_aRTVPlugins.Length; i++) {
        g_aRTVPlugins.GetString(i, Buffer, sizeof(Buffer));
        ServerCommand("sm plugins %s %s", Load ? "load" : "unload", Buffer);
    }
}

public void OnEntityCreated(int entity, const char[] classname) {
    if (g_Match.Status == Status_WarmUP) {
        if (StrEqual(classname, "weapon_c4") && IsValidEntity(entity)) {
            RemoveEntity(entity);
        }
    }
}

public Action ClearWeaponsItemsOnMap(Handle timer) {
    if (g_Match.Status != Status_WarmUP)
        return Plugin_Stop;
    
    char szClassname[32];
    for(int i = MaxClients + 1; i <= 2048; i++) {
        if (!IsValidEntity(i))
            continue;
        
        GetEntityClassname(i, szClassname, sizeof(szClassname));
        
        if ((StrContains(szClassname, "weapon_") != -1 || 
             StrContains(szClassname, "item_") != -1) &&
            GetEntPropEnt(i, Prop_Send, "m_hOwnerEntity") == -1) {
            char szEntityID[12];
            IntToString(i, szEntityID, sizeof(szEntityID));
            
            if (!g_Timer.PlayerDropedWeapon.ContainsKey(szEntityID)) {
                RemoveEntity(i);
            }
        }
    }
    return Plugin_Continue;
}

public Action NoticePlayersUnready(Handle timer) {
    if (g_Match.Status != Status_WarmUP)
        return Plugin_Stop;
        
    int unreadyCount = GetUnReadyCount();
    if (unreadyCount > 0) {
        char szUnreadyList[1024], szName[32], szSteamID[32];
        bool first = true;
        
        for(int i = 1; i <= MaxClients; i++) {
            if (!IsClientInGame(i) || IsClientSourceTV(i) || g_Client[i].isReady)
                continue;
                
            GetClientAuthId(i, AuthId_Steam3, szSteamID, sizeof(szSteamID));
            if(StrEqual(szSteamID, "BOT"))
                continue;

            GetClientName(i, szName, sizeof(szName));
            
            if (first) {
                Format(szUnreadyList, sizeof(szUnreadyList), "%s", szName);
                first = false;
            } else {
                Format(szUnreadyList, sizeof(szUnreadyList), "%s, %s", szUnreadyList, szName);
            }
        }
        CPrintToChatAll("{olive}[CSS] {default}当前未准备的玩家：{green}%s", szUnreadyList);
    } else {
        int needed = PLAYER_REQUIRED - GetClientCount();
        if (needed > 0) {
            CPrintToChatAll("{olive}[CSS] {default}全部玩家准备完毕，但还需 {red}%d {default}人才能开始比赛！", needed);
        } else {
            CPrintToChatAll("{olive}[CSS] {default}全部玩家准备完毕，比赛即将开始！");
        }
    }
    PrintHintTextToAll("可用指令:\n!ready(!r)准备-!unready(!un)取消准备\n!afk(切换观察者)-!unafk(取消)");
    return Plugin_Continue;
}

public Action ClearDropedWeapon(Handle timer, any data) {
    int weapon = view_as<int>(data);
    if (IsValidEntity(weapon)) {
        int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
        if (owner == -1 || !IsValidEntity(owner) || !IsClientInGame(owner)) {
            RemoveEntity(weapon);
        }
    }

    char szWeapon[12];
    IntToString(weapon, szWeapon, sizeof(szWeapon));
    if (g_Timer.PlayerDropedWeapon.ContainsKey(szWeapon)) {
        g_Timer.PlayerDropedWeapon.Remove(szWeapon);
    }
    return Plugin_Continue;
}

public void OnWeaponDropPost(int client, int weapon) {
    if (g_Match.Status != Status_WarmUP)
        return;

    char szWeapon[12];
    IntToString(weapon, szWeapon, sizeof(szWeapon));
    
    Handle existingTimer;
    if (g_Timer.PlayerDropedWeapon.GetValue(szWeapon, existingTimer)) {
        if (existingTimer != null) {
            delete existingTimer;
        }
    }

    g_Timer.PlayerDropedWeapon.SetValue(szWeapon, 
        CreateTimer(5.0, ClearDropedWeapon, weapon, TIMER_FLAG_NO_MAPCHANGE));
}

public void OnWeaponEquipPost(int client, int weapon) {
    if (g_Match.Status != Status_WarmUP)
        return;

    char szWeapon[12];
    IntToString(weapon, szWeapon, sizeof(szWeapon));
    
    Handle existingTimer;
    if (g_Timer.PlayerDropedWeapon.GetValue(szWeapon, existingTimer)) {
        if (existingTimer != null) {
            delete existingTimer;
        }
        g_Timer.PlayerDropedWeapon.Remove(szWeapon);
    }
}

public Action CS_OnTerminateRound(float &delay, CSRoundEndReason &reason) {
    if (g_Match.Status != Status_WarmUP && g_Match.Status != Status_End) {
        if (reason == CSRoundEnd_GameStart) InitWarmUP(INVALID_HANDLE);
        return Plugin_Continue;
    }
    delay = 100000.0;
    return Plugin_Stop;
}

public void OnClientPutInServer(int client) {
    InitClientData(client);
    SDKHook(client, SDKHook_WeaponDropPost, OnWeaponDropPost);
    SDKHook(client, SDKHook_WeaponEquipPost, OnWeaponEquipPost);
}

public void OnClientDisconnect(int client) {
    InitClientData(client);
    SDKUnhook(client, SDKHook_WeaponDropPost, OnWeaponDropPost);
    SDKUnhook(client, SDKHook_WeaponEquipPost, OnWeaponEquipPost);
}

public void OnClientDisconnect_Post(int client) {
    if (GetClientCount() < 1) {
        InitWarmUP(INVALID_HANDLE);
    }
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
    if (g_Match.Status == Status_End)
        return Plugin_Handled;
    return Plugin_Continue;
}

public void InitClientData(int client) {
    g_Client[client].isReady = false;
}

public void InitMatchData() {
    g_Match.MatchPlayers.Clear();
    g_Match.CurrentRound = 0;
    g_Match.OvertimeCount = 0;
    g_Match.CurrentRound_Overtime = 0;
}

public void InitPlayers() {
    for(int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsPlayerAlive(i))
            continue;
            
        // 移除所有武器
        for (int slot = 0; slot <= 1; slot++) {
            int weapon;
            while ((weapon = GetPlayerWeaponSlot(i, slot)) != -1) {
                RemovePlayerItem(i, weapon);
                RemoveEntity(weapon);
            }
        }
        for (int slot = 3; slot <= 3; slot++) {
            int weapon;
            while ((weapon = GetPlayerWeaponSlot(i, slot)) != -1) {
                RemovePlayerItem(i, weapon);
                RemoveEntity(weapon);
            }
        }

        // 给予默认武器
        GivePlayerItem(i, GetClientTeam(i) == CS_TEAM_CT ? "weapon_usp" : "weapon_glock");
        
        // 设置经济
        int money = (g_Match.Status >= Status_OverTime_FirstHalf) ? 16000 : 800;
        SetEntProp(i, Prop_Send, "m_iAccount", money);
        
        // 清除装备
        SetEntProp(i, Prop_Send, "m_bHasHelmet", 0);
        SetEntProp(i, Prop_Send, "m_ArmorValue", 0);
        SetEntProp(i, Prop_Send, "m_bHasDefuser", 0);
    }
}

public void AddPlayersToMatchList() {
    g_Match.MatchPlayers.Clear();
    char szSteamID[32];
    for(int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || (GetClientTeam(i) != CS_TEAM_T && GetClientTeam(i) != CS_TEAM_CT))
            continue;
        
        if (GetClientAuthId(i, AuthId_Steam3, szSteamID, sizeof(szSteamID))) {
            g_Match.MatchPlayers.SetValue(szSteamID, GetClientTeam(i));
        }
    }
}

public void PrintMoneyStatus() {
    for(int team = CS_TEAM_T; team <= CS_TEAM_CT; team++) {
        char teamName[16];
        Format(teamName, sizeof(teamName), team == CS_TEAM_T ? "T" : "CT");
        
        CPrintToChatAll("{green}%s 队伍经济：", teamName);
        
        for(int i = 1; i <= MaxClients; i++) {
            if (!IsClientInGame(i) || GetClientTeam(i) != team || !IsPlayerAlive(i))
                continue;
                
            char name[32];
            GetClientName(i, name, sizeof(name));
            CPrintToChatAll("{default}$%d -> {lightgreen}%s", GetEntProp(i, Prop_Send, "m_iAccount"), name);
        }
    }
}

public void SwapTeam() {
    ArrayList TeamT = new ArrayList();
    ArrayList TeamCT = new ArrayList();
    
    for(int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i))
            continue;
            
        if(GetClientTeam(i) == CS_TEAM_T) TeamT.Push(i);
        if(GetClientTeam(i) == CS_TEAM_CT) TeamCT.Push(i);
    }
    
    for(int i = 0; i < TeamT.Length; i++) {
        int client = TeamT.Get(i);
        CS_SwitchTeam(client, CS_TEAM_CT);
    }
    
    for(int i = 0; i < TeamCT.Length; i++) {
        int client = TeamCT.Get(i);
        CS_SwitchTeam(client, CS_TEAM_T);
    }
    
    delete TeamT;
    delete TeamCT;

    // 交换比分
    int scoreT = CS_GetTeamScore(CS_TEAM_T);
    int scoreCT = CS_GetTeamScore(CS_TEAM_CT);
    
    CS_SetTeamScore(CS_TEAM_T, scoreCT);
    CS_SetTeamScore(CS_TEAM_CT, scoreT);
    
    // 更新玩家队伍信息
    StringMapSnapshot snapshot = g_Match.MatchPlayers.Snapshot();
    char szSteamID[32];
    int team;
    
    for(int i = 0; i < snapshot.Length; i++) {
        snapshot.GetKey(i, szSteamID, sizeof(szSteamID));
        g_Match.MatchPlayers.GetValue(szSteamID, team);
        
        if (team == CS_TEAM_T) {
            g_Match.MatchPlayers.SetValue(szSteamID, CS_TEAM_CT);
        } else if (team == CS_TEAM_CT) {
            g_Match.MatchPlayers.SetValue(szSteamID, CS_TEAM_T);
        }
    }
    
    delete snapshot;
}

stock int GetUnReadyCount() {
    int count = 0;
    char szSteamID[32];
    
    for(int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || IsClientSourceTV(i) || g_Client[i].isReady)
            continue;
            
        if (GetClientAuthId(i, AuthId_Steam3, szSteamID, sizeof(szSteamID)) && 
            !StrEqual(szSteamID, "BOT")) {
            count++;
        }
    }
    return count;
}

stock int GetMatchingPlayerCount() {
    int count = 0;
    char szSteamID[32];
    
    for(int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || IsClientSourceTV(i) || 
            (GetClientTeam(i) != CS_TEAM_T && GetClientTeam(i) != CS_TEAM_CT))
            continue;
            
        if (GetClientAuthId(i, AuthId_Steam3, szSteamID, sizeof(szSteamID)) && 
            !StrEqual(szSteamID, "BOT")) {
            count++;
        }
    }
    return count;
}

stock StringMap GetUnMatchingPlayersStringMap() {
    StringMap unMatching = new StringMap();
    StringMapSnapshot snapshot = g_Match.MatchPlayers.Snapshot();
    char szSteamID[32];
    
    // 获取所有在比赛列表中的玩家
    for(int i = 0; i < snapshot.Length; i++) {
        snapshot.GetKey(i, szSteamID, sizeof(szSteamID));
        int team;
        g_Match.MatchPlayers.GetValue(szSteamID, team);
        unMatching.SetValue(szSteamID, team);
    }
    
    delete snapshot;
    
    // 移除当前在线的玩家
    for(int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i))
            continue;
            
        if (GetClientAuthId(i, AuthId_Steam3, szSteamID, sizeof(szSteamID))) {
            if (unMatching.ContainsKey(szSteamID)) {
                unMatching.Remove(szSteamID);
            }
        }
    }
    
    return unMatching;
}

#if defined _DEBUG
public Action GotoRound(int client, int args) {
    if (args < 2) {
        ReplyToCommand(client, "用法: gotoround <CT分数> <T分数>");
        return Plugin_Handled;
    }
    
    char arg1[8], arg2[8];
    GetCmdArg(1, arg1, sizeof(arg1));
    GetCmdArg(2, arg2, sizeof(arg2));
    
    int ctScore = StringToInt(arg1);
    int tScore = StringToInt(arg2);
    int total = ctScore + tScore;
    
    if (g_Match.Status == Status_WarmUP) {
        g_Match.Status = Status_Started;
        ServerCommand("mp_restartgame 1");
    }
    
    CS_SetTeamScore(CS_TEAM_CT, ctScore);
    SetTeamScore(CS_TEAM_CT, ctScore);
    CS_SetTeamScore(CS_TEAM_T, tScore);
    SetTeamScore(CS_TEAM_T, tScore);
    
    g_Match.CurrentRound = total;
    
    if (total <= 15) {
        g_Match.Status = Status_FirstHalf;
    } else if (total <= 29) {
        g_Match.Status = Status_SecondHalf;
    } else if (total <= 32) {
        g_Match.Status = Status_OverTime_FirstHalf;
        g_Match.OvertimeCount = 1;
        g_Match.CurrentRound_Overtime = total - 29;
    } else if (total <= 35) {
        g_Match.Status = Status_OverTime_SecondHalf;
        g_Match.OvertimeCount = 1;
        g_Match.CurrentRound_Overtime = total - 29;
    }
    
    ReplyToCommand(client, "已设置回合: CT %d - %d T", ctScore, tScore);
    return Plugin_Handled;
}
#endif