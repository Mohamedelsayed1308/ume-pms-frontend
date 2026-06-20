import api from './api';

export interface User {
  id: string;
  email: string;
  full_name: string;
  is_active: boolean;
  roles: any[];
}

export interface AuthResponse {
  access_token: string;
  refresh_token: string;
  user: User;
}

export const login = async (email: string, password: string): Promise<AuthResponse> => {
  const { data } = await api.post('/api/v1/auth/login', { email, password });
  localStorage.setItem('access_token', data.access_token);
  localStorage.setItem('refresh_token', data.refresh_token);
  localStorage.setItem('user', JSON.stringify(data.user));
  return data;
};

export const logout = () => {
  localStorage.removeItem('access_token');
  localStorage.removeItem('refresh_token');
  localStorage.removeItem('user');
  window.location.href = '/login';
};

export const getUser = (): User | null => {
  if (typeof window === 'undefined') return null;
  const user = localStorage.getItem('user');
  return user ? JSON.parse(user) : null;
};

export const isAuthenticated = (): boolean => {
  if (typeof window === 'undefined') return false;
  return !!localStorage.getItem('access_token');
};
