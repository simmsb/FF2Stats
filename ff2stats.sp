/*

freak fortress 2 status, written by nitros


that big TODO: list
  Easy/ Med/ Hard gamemodes?
*/


#pragma semicolon 1

#include <sourcemod>
#include <freak_fortress_2>
#include <clientprefs>

#define PLUGIN_VERSION "0.1.7"

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
  HookEvent("teamplay_round_start", OnRoundStart);
  HookEvent("teamplay_round_win", OnRoundEnd);
  RegConsoleCmd("ff2stats", statsToggleCmd);
  LoadTranslations("ff2stats.phrases");
  g_ff2statsenabled = CreateConVar("ff2stats_enabled", "1.0", "enables or disables ff2stats globally", FCVAR_PROTECTED, true, 0.0, true, 1.0);
}


public Action OnRoundStart(Handle event, char[] name, bool dontBroadcast) {
  if (!FF2_IsFF2Enabled() || !g_ff2statsenabled.IntValue)  {
    return Plugin_Continue;
  }

  int boss = -1;
  for (int client; client<MaxClients; client++) {
    if (IsValidClient(client)) {
      if (!StatsEnabledForClient(client)) {
        continue;
      } // dont add if not counting stats
      boss = FF2_GetBossIndex(client);
      if (!(boss==-1)) { // we have a boss
        DataPack pack;
        CreateDataTimer(1.2, setBossHealthTimer, pack, TIMER_FLAG_NO_MAPCHANGE); //idk
        pack.WriteCell(boss);
        pack.WriteCell(client);
      }
    }
  }
  return Plugin_Continue;
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


//  Calculate hp modifier
//
//
//    win_percentage <float>: win percentage (win/ total)
//    base_hp <int>: base hp to calculate off
int calcHpMod(float win_percentage, int base_hp) {
  float multiplier = F_CLAMP(Pow(win_percentage-0.5, 2.0) * (-F_SIGN(win_percentage-0.5)), -0.5, 0.5) + 1.0;
  PrintToChatAll("multiplier was: %f", multiplier);
  return RoundFloat(multiplier * base_hp);
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
//    steamID <int>: Steamid of client
//    bossName <char[]>: name of boss (Only thing that is garunteed to not change often)
//    win <bool>:  true -> boss won, false -> boss lost
void addGameToDB(int steamID, const char[] bossName, bool win) {
  char Query[255];

  /* Create enough space to make sure our string is quoted properly  */
  int bufferLen = strlen(bossName) * 2 + 1;
  char[] newName = new char[bufferLen];

  /* Ask the SQL driver to make sure our string is safely quoted */
  SQL_EscapeString(db, bossName, newName, bufferLen);

  /* Build the Query */
  Format(Query, sizeof(Query), "INSERT INTO %s (steamid, bossname, win) VALUES (%d, '%s', %d);", STATS_TABLE, steamID, newName, win);
  /* Execute the Query */
  SQL_LockDatabase(db);
  SQL_FastQuery(db, Query);
  SQL_UnlockDatabase(db);
}


//      Gets player win - loss stats as a certain boss
//
//    steamID <int>: steamid of player
//    bossName <char[]>: name of boss
//    win <&int>: pointer to win variable to insert win count into
//    loss <&int>: pointer to loss variable to insert loss count into
void getPlayerWinsAsBoss(int steamID, const char[] bossName, int &win, int &loss) {
  DBResultSet hQuery;
  char Query[255];

  int bufferLen = strlen(bossName) * 2 + 1;
  char[] newName = new char[bufferLen];

  SQL_EscapeString(db, bossName, newName, bufferLen);

  Format(Query, sizeof(Query), "SELECT sum(win), count(win) - sum(win) FROM %s WHERE steamid=%d and bossname='%s';", STATS_TABLE, steamID, newName);
  if ((hQuery = SQL_Query(db, Query)) == null) {
    win = 0;  // if it errors, return 1:1 ratio
    loss = 0;
  }

  SQL_FetchRow(hQuery);
  win = SQL_FetchInt(hQuery, 0);
  loss = SQL_FetchInt(hQuery, 1);

  delete hQuery;
}


removeUserStats(int steamID) {
  char Query[255];

  Format(Query, sizeof(Query), "DELETE FROM %s WHERE steamid=%d;", STATS_TABLE, steamID);

  SQL_LockDatabase(db);
  SQL_FastQuery(db, Query);
  SQL_UnlockDatabase(db);
}


//    Timer to hande the boss health mod after boss generation (pray this doesn't grab the last boss's hp or some garbage)
public Action setBossHealthTimer(Handle timer, Handle pack) {
  int boss;
  int client;

  ResetPack(pack);
  boss = ReadPackCell(pack);
  client = ReadPackCell(pack);

  int bossSteamID = GetSteamAccountID(client); // steamid
  if (bossSteamID == 0) {  // dont break on invalid steamid
    return Plugin_Continue;
  }
  char bossName[255];
  FF2_GetBossSpecial(boss, bossName, sizeof(bossName));

  int win, loss;
  float ratio;
  getPlayerWinsAsBoss(bossSteamID, bossName, win, loss);
  ratio = (win+loss) > 0? float(win)/float(loss) : 0.5;  // use 0.5 if 0 total
  int bossHp = FF2_GetBossMaxHealth(boss);
  int newHp = calcHpMod(ratio, bossHp);

  CPrintToChatAll("{olive}[FF2stats]{default} %N has FF2stats enabled and was given a health modifier of %d! (%d win: %d loss)", client, newHp-bossHp, win, loss);
  PrintToChatAll("Base hp: %d, new hp: %d, lives: %d", bossHp, newHp, FF2_GetBossLives(boss));
  FF2_SetBossMaxHealth(boss, newHp);
  FF2_SetBossHealth(boss, newHp*FF2_GetBossLives(boss)); // also set boss health, because it likes to break it somewhere else
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
