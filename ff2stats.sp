/*

freak fortress 2 status, written by nitros


that big TODO: list

on round start:
  do stats stuff
  hp mod:
    (wins / (wins + loss)) => win_percentage  <- Done in SQL

    new_mod = ((win_percentage^2) * sign(win_percentage)) <- Done in SM

  Easy/ Med/ Hard gamemodes?
*/

// TODO: Move these func somewhere else once implemented
int calcHpMod(float win_percentage, int base_hp) {
  float multiplier = F_CLAMP(pow(win_percentage, 2.0) * F_SIGN(win_percentage), -0.5, 0.5) + 1.0;
  return FloatRound(multiplier * base_hp);
}

float F_CLAMP(float val, float min, float max) {
  if (val < min) {
    return min;
  } else if (val > max) {
    return max;
  } else {
    return val;
  }
}

float F_SIGN(float val){
  return val>0.0 ? 1.0 : -1.0;
}

#pragma semicolon 1

#include <sourcemod>
#include <freak_fortress_2>
#include <clientprefs>

#define PLUGIN_VERSION "0.1.1"

#define STATS_COOKIE "ff2stats_onforuser"
#define STATS_TABLE "player_stats"


public Plugin myinfo = {
  name="Freak Fortress Stats",
  author="Nitros",
  description="Boss stats for freak fortress 2",
  version=PLUGIN_VERSION,
  url="ben@bensimms.moe"
};

Handle g_bossStatsCookie;
Handle db;

ConVar g_ff2statsenabled;

public void OnPluginStart() {
  g_bossStatsCookie = RegClientCookie(STATS_COOKIE, "Enable stats for user", CookieAccess_Protected);
  InitDB(db);
  HookEvent("teamplay_round_win", OnRoundEnd);
  RegConsoleCmd("ff2stats", statsToggleCmd);
  LoadTranslations("ff2stats.phrases");
  g_ff2statsenabled = CreateConVar("ff2stats_enabled", "0.0", "enables or disables ff2stats globally", FCVAR_PROTECTED, true, 0.0, true, 1.0);
}


//
//      STATS CLEARING MENU
//
public Action statsClearCmd(int client, int args) {
  if (!IsValidClient(client)) {
    return Plugin_Handled;
  }

  statsClearPanel(client);
  return Plugin_Handled;
}

public Action statsClearPanel(int client) {
  Handle panel=CreatePanel();
  SetPanelTitle(panel, "Are you sure you want to clear your boss stats!");
  DrawPanelItem(panel, "Yes");
  DrawPanelItem(panel, "No");
  SendPanelToClient(panel, client, statsClearPanelH, MENU_TIME_FOREVER);
  CloseHandle(panel);
  return Plugin_Handled;
}

public statsClearPanelH(Handle menu, MenuAction action, int client, int selection) {
  if (IsValidClient(client) && action==MenuAction_Select) {
    if (selection==1) { //Yes
      removeUserStats(GetSteamAccountID(client));
      CPrintToChat(client, "{olive}[FF2stats]{default} Cleared your boss stats!");
    }
  }
}
//
//
//


//
//      STATS TOGGLE MENU
//
public Action statsToggleCmd(int client, int args) {
  if (!IsValidClient(client)) {
    return Plugin_Handled;
  }

  statsTogglePanel(client);
  return Plugin_Handled;
}

public Action statsTogglePanel(int client)
{
  Handle panel = CreatePanel();
  SetPanelTitle(panel, "Enable or disable boss stats");
  DrawPanelItem(panel, "On");
  DrawPanelItem(panel, "Off");
  SendPanelToClient(panel, client, statsTogglePanelH, MENU_TIME_FOREVER);
  CloseHandle(panel);
  return Plugin_Handled;
}

public statsTogglePanelH(Handle menu, MenuAction action, int client, int selection)
{
  if (IsValidClient(client) && action==MenuAction_Select) {
    if (selection==2) { //Off
      setStatsCookie(client, false);
    }
    else { //on
      setStatsCookie(client, true);
    }
    CPrintToChat(client, "{olive}[FF2stats]{default} FF2stats are %t for you!", selection==2 ? "off" : "on");
  }
}
//
//
//


InitDB(Handle &DBHandle) {
  char Error[255];
  DBHandle = SQL_Connect("default", true, Error, sizeof(Error));

  if (DBHandle == INVALID_HANDLE) {
    SetFailState(Error);
  }
  char Query[255];
  Format(Query, sizeof(Query), "CREATE TABLE IF NOT EXISTS %s (steamid INT, bossname TEXT, win INT)", STATS_TABLE);
  SQL_LockDatabase(DBHandle);
  SQL_FastQuery(DBHandle, Query);
  SQL_UnlockDatabase(DBHandle);
}


//  set stats cookie for client, type: bool
setStatsCookie(int client, bool val) {
  if (!IsValidClient(client) || IsFakeClient(client) || !AreClientCookiesCached(client)) {
    return;
  }
  char cookieVal[8];
  IntToString(val, cookieVal, sizeof(cookieVal));
  SetClientCookie(client, g_bossStatsCookie, cookieVal);
}


//  Get val of stats cookie for client
bool StatsEnabledForClient(int client) {
  if (!AreClientCookiesCached(client)) {// not loaded? dont run
    return false;
  }
  char sValue[4];
  GetClientCookie(client, g_bossStatsCookie, sValue, sizeof(sValue));
  return (sValue[0] != '\0' && StringToInt(sValue));
}


// insert game into database
//
//    steamid <int>: Steamid of client
//    boss_name <char[]>: name of boss (Only thing that is garunteed to not change often)
//    win <bool>:  true -> boss won, false -> boss lost
void addGameToDB(int steamid, const char[] boss_name, bool win) {
  char Query[255];

  /* Create enough space to make sure our string is quoted properly  */
  int buffer_len = strlen(boss_name) * 2 + 1;
  char[] new_boss_name = new char[buffer_len];

  /* Ask the SQL driver to make sure our string is safely quoted */
  SQL_EscapeString(db, boss_name, new_boss_name, buffer_len);

  /* Build the Query */
  Format(Query, sizeof(Query), "INSERT INTO %s (steamid, bossname, win) VALUES (%d, '%s', %d);", STATS_TABLE, steamid, new_boss_name, win);
  /* Execute the Query */
  SQL_LockDatabase(db);
  SQL_FastQuery(db, Query);
  SQL_UnlockDatabase(db);
}


removeUserStats(int steamid) {
  char Query[255];

  Format(Query, sizeof(Query), "DELETE FROM %s WHERE steamid=%d;", STATS_TABLE, steamid);

  SQL_LockDatabase(db);
  SQL_FastQuery(db, Query);
  SQL_UnlockDatabase(db);
}


public Action OnRoundEnd(Handle event, char[] name, bool dontBroadcast) {
  if (!FF2_IsFF2Enabled() || !g_ff2statsenabled.IntValue) {
    return Plugin_Continue;
  }
  bool bossWin = false;
  if ((GetEventInt(event, "team") == FF2_GetBossTeam())) {
    bossWin=true; // boss won
  }
  char bossName[255];
  int boss = -1;
  for (int client; client<MaxClients; client++) {
    if (IsValidClient(client)) {
      if (!StatsEnabledForClient(client)) {
        continue;
      } // dont add if not counting stats
      boss = FF2_GetBossIndex(client);
      if (!(boss==-1)) { // we have a boss
        int bossSteamID = GetSteamAccountID(client); // steamid
        if (bossSteamID == 0) {
          continue;
        } // dont break on invalid steamid
        FF2_GetBossSpecial(boss, bossName, sizeof(bossName));
        CPrintToChat(client, "{olive}[FF2stats]{default} FF2stats are enabled for you, a %s was counted for %s.", bossWin==true ? "win" : "loss", bossName);
        addGameToDB(bossSteamID, bossName, bossWin);
      }
    }
  }

  return Plugin_Continue;
}

stock bool IsValidClient(int client, bool replaycheck=true) {
  if (client<=0 || client>MaxClients) {
    return false;
  }

  if (!IsClientInGame(client)) {
    return false;
  }

  if (GetEntProp(client, Prop_Send, "m_bIsCoaching")) {
    return false;
  }

  if (replaycheck) {
    if (IsClientSourceTV(client) || IsClientReplay(client)) {
      return false;
    }
  }
  return true;
}
